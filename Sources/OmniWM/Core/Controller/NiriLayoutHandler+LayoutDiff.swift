// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

struct NiriLayoutDiffContext {
    let engine: NiriLayoutEngine
    let workspaceId: WorkspaceDescriptor.ID
    let canRestoreHiddenWorkspaceWindows: Bool
    let reassertHidden: Bool
    var excludedTokens: Set<WindowToken> = []
    var pendingParkWindowIds: Set<Int> = []
    var settledContext: (monitor: LayoutMonitorSnapshot, state: ViewportState)?
}

extension NiriLayoutHandler {
    func computeLayoutPlan(
        pass: NiriLayoutPass,
        state: ViewportState,
        selection: (viewportNeedsRecalc: Bool, rememberedFocusToken: WindowToken?),
        arrival: ArrivalContext,
        snapshot: NiriWorkspaceSnapshot
    ) -> WorkspaceLayoutPlan {
        let rememberedFocusToken = arrival.rememberedFocusToken ?? selection.rememberedFocusToken
        let isSettled = !(pass.motion.animationsEnabled && snapshot.removalSeed?.oldFrames.isEmpty == false)
            && controller.map {
                !hasPendingNiriAnimationWork(
                    state: state,
                    driver: $0.workspaceManager.animationDriver,
                    engine: pass.engine,
                    workspaceId: pass.wsId
                )
            } == true
        let (frames, hiddenHandles) = calculateRelayoutFrames(
            pass: pass, state: state, snapshot: snapshot, isSettled: isSettled
        )

        var directives = relayoutAnimationDirectives(
            pass: pass, state: state, snapshot: snapshot,
            viewportNeedsRecalc: selection.viewportNeedsRecalc, arrival: arrival
        )

        var diff = layoutDiff(
            windows: snapshot.windows,
            frames: frames,
            hiddenHandles: hiddenHandles,
            context: NiriLayoutDiffContext(
                engine: pass.engine,
                workspaceId: pass.wsId,
                canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace,
                reassertHidden: true,
                excludedTokens: snapshot.excludedTokens,
                settledContext: isSettled ? (snapshot.monitor, state) : nil
            )
        )
        diff.edgeHiddenFrames = edgeHiddenFrames(engine: pass.engine, snapshot: snapshot)
        diff.picturePreparation = picturePreparation(
            engine: pass.engine, snapshot: snapshot, state: state, isSettled: isSettled
        )
        let hasPendingAnimationWork = completeAnimationDirectives(&directives, pass: pass, state: state)
        return WorkspaceLayoutPlan(
            workspaceId: pass.wsId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: pass.wsId,
                viewportState: state,
                rememberedFocusToken: rememberedFocusToken,
                plannedSeq: snapshot.plannedSeq
            ),
            diff: diff,
            animationDirectives: directives,
            isActiveWorkspace: snapshot.isActiveWorkspace,
            isSlideInFlight: hasPendingAnimationWork
        )
    }

    func edgeHiddenFrames(engine: NiriLayoutEngine, snapshot: NiriWorkspaceSnapshot) -> [WindowToken: CGRect] {
        engine.layoutPool.edgeHiddenFrames.filter { token, _ in
            snapshot.windows.contains { $0.token == token && !$0.isNativeFullscreenSuspended }
                && !snapshot.excludedTokens.contains(token)
        }
    }

    func layoutDiff(
        windows: [LayoutWindowSnapshot],
        frames: [WindowToken: CGRect],
        hiddenHandles: [WindowToken: HideSide],
        context: NiriLayoutDiffContext
    ) -> WorkspaceLayoutDiff {
        var diff = WorkspaceLayoutDiff()
        let workspace = context.engine.states[context.workspaceId]
        for window in windows {
            let token = window.token
            if window.isNativeFullscreenSuspended {
                appendNativeFullscreenSlot(
                    window,
                    frames: frames,
                    hiddenHandles: hiddenHandles,
                    context: context,
                    diff: &diff
                )
                continue
            }
            if context.excludedTokens.contains(token) { continue }
            let previousOffscreenSide = window.hiddenState?.offscreenSide
            if let side = hiddenHandles[token] {
                if previousOffscreenSide != side || context.reassertHidden
                    || context.pendingParkWindowIds.contains(token.windowId)
                {
                    diff.visibilityChanges.append(.hide(token, side: side))
                }
                continue
            }
            if previousOffscreenSide != nil, frames[token] != nil {
                diff.visibilityChanges.append(.show(token))
            }
            if context.canRestoreHiddenWorkspaceWindows,
               let hiddenState = window.hiddenState,
               hiddenState.workspaceInactive
            {
                diff.restoreChanges.append(.init(token: token, hiddenState: hiddenState))
            }
            guard let frame = frames[token] else { continue }
            diff.frameChanges.append(layoutFrameChange(
                token: token, frame: frame, node: workspace?.nodesByToken[token], context: context
            ))
        }
        return diff
    }

    private func appendNativeFullscreenSlot(
        _ window: LayoutWindowSnapshot,
        frames: [WindowToken: CGRect],
        hiddenHandles: [WindowToken: HideSide],
        context: NiriLayoutDiffContext,
        diff: inout WorkspaceLayoutDiff
    ) {
        guard let originalToken = window.nativeFullscreenOriginalToken else { return }
        let token = window.token
        let frame = frames[token]
        let validFrame = frame.map { !$0.isNull && !$0.isInfinite && $0.width > 1 && $0.height > 1 } == true
        diff.nativeFullscreenSlots[originalToken] = NativeFullscreenSlotProjection(
            currentToken: token,
            frame: validFrame ? frame ?? .zero : .zero,
            visible: context.canRestoreHiddenWorkspaceWindows
                && !context.excludedTokens.contains(token)
                && hiddenHandles[token] == nil
                && validFrame
        )
    }

    private func layoutFrameChange(
        token: WindowToken,
        frame: CGRect,
        node: NiriWindow?,
        context: NiriLayoutDiffContext
    ) -> LayoutFrameChange {
        var change = LayoutFrameChange(
            token: token,
            frame: frame,
            forceApply: node?.sizingMode == .fullscreen
        )
        if let settledContext = context.settledContext,
           settledContext.monitor.orientation == .horizontal,
           frame.minX < settledContext.monitor.frame.minX,
           let node, node.sizingMode == .normal,
           node.id != settledContext.state.selectedNodeId,
           let column = context.engine.column(of: node),
           context.engine.columnIndex(of: column, in: context.workspaceId) != settledContext.state.activeColumnIndex,
           let axManager = controller?.axManager,
           axManager.animationFrameComponents(for: token.windowId, targetFrame: frame) == .position,
           let nativeFrame = axManager.lastAppliedFrame(for: token.windowId)
        {
            let screenFrame = settledContext.monitor.frame
            let anchor = NiriMonitorPlaneGeometry.clampedFrame(
                frame.offsetBy(dx: screenFrame.minX - frame.maxX, dy: 0),
                screenClampRect: screenFrame,
                orientation: .horizontal
            )
            if frame.minX == anchor.minX {
                let nativePlacement = CGRect(
                    x: screenFrame.minX - nativeFrame.width,
                    y: frame.maxY - nativeFrame.height,
                    width: nativeFrame.width,
                    height: nativeFrame.height
                )
                change = change.writing(
                    NiriMonitorPlaneGeometry.clampedFrame(
                        nativePlacement,
                        screenClampRect: screenFrame,
                        orientation: .horizontal
                    ),
                    components: .position
                )
            }
        }
        return change
    }

    private func calculateRelayoutFrames(
        pass: NiriLayoutPass,
        state: ViewportState,
        snapshot: NiriWorkspaceSnapshot,
        isSettled: Bool
    ) -> (frames: [WindowToken: CGRect], hiddenHandles: [WindowToken: HideSide]) {
        let gaps = LayoutGaps(
            horizontal: pass.gap,
            vertical: pass.gap
        )

        let area = WorkingAreaContext(
            workingFrame: pass.insetFrame,
            singleWindowFrame: snapshot.monitor.workingFrame,
            borderSafeFillFrame: snapshot.monitor.borderSafeFillFrame,
            fullscreenLayoutFrame: snapshot.fullscreenLayoutFrame,
            viewFrame: snapshot.monitor.frame,
            scale: snapshot.monitor.scale
        )

        return pass.engine.calculateCombinedLayoutUsingPools(
            in: pass.wsId,
            monitor: pass.monitor,
            gaps: gaps,
            state: state,
            workingArea: area,
            animationTime: nil,
            viewOffsetOverride: controller.map {
                $0.workspaceManager.animationDriver.plannedRenderOffset(
                    in: pass.wsId,
                    localState: state,
                    storeOffset: $0.workspaceManager.niriViewportState(for: pass.wsId).viewOffset
                )
            },
            isSettled: isSettled,
            excludedTokens: snapshot.excludedTokens, edgePictures: snapshot.edgePictures,
            recordsPresentationGeometry: true
        )
    }

    private func relayoutAnimationDirectives(
        pass: NiriLayoutPass,
        state: ViewportState,
        snapshot: NiriWorkspaceSnapshot,
        viewportNeedsRecalc: Bool,
        arrival: ArrivalContext
    ) -> [AnimationDirective] {
        let activateWindowToken = arrival.activateWindowToken
        let hasNewWindowArrival = arrival.hasNewWindowArrival
        let shouldStartScrollForNewWindow = arrival.shouldStartScrollForNewWindow
        let hasColumnAnimations = pass.engine.hasAnyColumnAnimationsRunning(in: pass.wsId)
        var directives: [AnimationDirective] = []

        if viewportNeedsRecalc,
           !hasNewWindowArrival,
           !snapshot.useScrollAnimationPath || state.hasPendingOffsetAnimation
        {
            directives.append(.startNiriScroll(workspaceId: pass.wsId))
        } else if !snapshot.useScrollAnimationPath, hasColumnAnimations {
            directives.append(.startNiriScroll(workspaceId: pass.wsId))
        }

        if let activateWindowToken {
            if shouldStartScrollForNewWindow {
                directives.append(.startNiriScroll(workspaceId: pass.wsId))
            }
            directives.append(.activateWindow(token: activateWindowToken))
        }

        if let removalSeed = snapshot.removalSeed, !removalSeed.oldFrames.isEmpty {
            let newFrames = pass.engine.captureWindowFrames(
                in: pass.wsId,
                excluding: snapshot.excludedTokens
            )
            let animationsTriggered = pass.engine.triggerMoveAnimations(
                in: pass.wsId,
                oldFrames: removalSeed.oldFrames,
                newFrames: newFrames,
                motion: pass.motion
            )
            let hasWindowAnimations = pass.engine.hasAnyWindowAnimationsRunning(in: pass.wsId)
            let hasColumnAnimations = pass.engine.hasAnyColumnAnimationsRunning(in: pass.wsId)
            if animationsTriggered || hasWindowAnimations || hasColumnAnimations {
                directives.append(.startNiriScroll(workspaceId: pass.wsId))
            }
        }

        return directives
    }

    private func completeAnimationDirectives(
        _ directives: inout [AnimationDirective],
        pass: NiriLayoutPass,
        state: ViewportState
    ) -> Bool {
        let startsAnimation = directives.contains {
            if case .startNiriScroll = $0 { return true }
            return false
        }
        let hasPendingAnimationWork = controller.map {
            hasPendingNiriAnimationWork(
                state: state,
                driver: $0.workspaceManager.animationDriver,
                engine: pass.engine,
                workspaceId: pass.wsId
            )
        } == true
        let hasRegisteredAnimation = hasScrollAnimation(for: pass.wsId)
        if hasPendingAnimationWork, !startsAnimation, !hasRegisteredAnimation {
            directives.append(.startNiriScroll(workspaceId: pass.wsId))
        }
        return hasPendingAnimationWork
    }
}
