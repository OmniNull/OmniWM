// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    func layoutDiffContext(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine,
        reassertHidden: Bool,
        animationTime: TimeInterval?
    ) -> DwindleLayoutDiffContext {
        DwindleLayoutDiffContext(
            engine: engine,
            workspaceId: snapshot.workspaceId,
            preferredHideSide: snapshot.preferredHideSide,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace,
            scale: snapshot.monitor.scale,
            reassertHidden: reassertHidden,
            pendingParkWindowIds: controller?.axManager.pendingParks(includingMoved: animationTime == nil) ?? [],
            animationTime: animationTime
        )
    }

    func layoutDiff(
        windows: [LayoutWindowSnapshot],
        frames: [WindowToken: CGRect],
        context: DwindleLayoutDiffContext
    ) -> WorkspaceLayoutDiff {
        var diff = WorkspaceLayoutDiff()
        diff.frameChanges.reserveCapacity(frames.count)
        let effectiveScale = max(context.scale, 1.0)
        let excludedTokens = context.engine.excludedTokens(in: context.workspaceId)
        let liveFloatingFrame = context.engine.liveMoveWorkspaceId == context.workspaceId
            ? context.engine.liveTabMoveFloatingFrame : nil
        let move = context.engine.interactiveMove
        let floatingFrame = liveFloatingFrame ?? (move?.workspaceId == context.workspaceId ? move?.floatingFrame : nil)
        let floatingToken = liveFloatingFrame != nil ? context.engine.liveTabMoveToken : move?.token
        func frame(for token: WindowToken) -> CGRect? {
            guard let target = frames[token] else { return nil }
            guard let time = context.animationTime else { return target }
            return context.engine.presentedFrame(for: token, in: context.workspaceId, at: time) ?? target
        }
        for window in windows {
            let token = window.token
            if window.isNativeFullscreenSuspended {
                if let originalToken = window.nativeFullscreenOriginalToken {
                    diff.nativeFullscreenSlots[originalToken] = nativeFullscreenSlot(
                        token: token,
                        frame: frame(for: token)?.roundedToPhysicalPixels(scale: effectiveScale),
                        context: context,
                        excludedTokens: excludedTokens
                    )
                }
                continue
            }
            if excludedTokens.contains(token) {
                continue
            }
            if let floatingFrame, token == floatingToken {
                if window.hiddenState != nil { diff.visibilityChanges.append(.show(token)) }
                diff.frameChanges.append(LayoutFrameChange(
                    token: token, frame: floatingFrame.roundedToPhysicalPixels(scale: effectiveScale), forceApply: false
                ))
                continue
            }
            if appendInactiveGroupVisibility(window, windows: windows, frames: frames, context: context, diff: &diff) {
                continue
            }
            appendVisibleFrame(
                frame(for: token), for: window, context: context, scale: effectiveScale, diff: &diff
            )
        }
        return diff
    }

    private func appendVisibleFrame(
        _ frame: CGRect?,
        for window: borrowing LayoutWindowSnapshot,
        context: borrowing DwindleLayoutDiffContext,
        scale: CGFloat,
        diff: inout WorkspaceLayoutDiff
    ) {
        let token = window.token
        if window.hiddenState?.offscreenSide != nil, frame != nil {
            diff.visibilityChanges.append(.show(token))
        }
        if context.canRestoreHiddenWorkspaceWindows,
           let hiddenState = window.hiddenState,
           hiddenState.workspaceInactive
        {
            diff.restoreChanges.append(.init(token: token, hiddenState: hiddenState))
        }
        guard let frame = frame?.roundedToPhysicalPixels(scale: scale) else { return }
        diff.frameChanges.append(LayoutFrameChange(
            token: token, frame: frame,
            forceApply: context.engine.isWindowFullscreen(token, in: context.workspaceId)
        ))
    }

    private func nativeFullscreenSlot(
        token: WindowToken,
        frame: CGRect?,
        context: DwindleLayoutDiffContext,
        excludedTokens: Set<WindowToken>
    ) -> NativeFullscreenSlotProjection {
        let validFrame = frame.map { !$0.isNull && !$0.isInfinite && $0.width > 1 && $0.height > 1 } == true
        return NativeFullscreenSlotProjection(
            currentToken: token,
            frame: validFrame ? frame ?? .zero : .zero,
            visible: context.canRestoreHiddenWorkspaceWindows
                && !excludedTokens.contains(token)
                && context.engine.activeTileMember(containing: token, in: context.workspaceId) == token
                && validFrame
        )
    }

    private func appendInactiveGroupVisibility(
        _ window: LayoutWindowSnapshot,
        windows: [LayoutWindowSnapshot],
        frames: [WindowToken: CGRect],
        context: DwindleLayoutDiffContext,
        diff: inout WorkspaceLayoutDiff
    ) -> Bool {
        let token = window.token
        guard context.engine.isInactiveGroupMember(token, in: context.workspaceId) else { return false }
        let previousOffscreenSide = window.hiddenState?.offscreenSide
        let side = previousOffscreenSide ?? context.preferredHideSide
        if previousOffscreenSide == nil,
           let revealToken = context.engine.activeTileMember(containing: token, in: context.workspaceId),
           let revealWindow = windows.first(where: { $0.token == revealToken }),
           revealWindow.hiddenState?.offscreenSide != nil,
           frames[revealToken] != nil
        {
            diff.deferredHides.append(
                LayoutDeferredHide(
                    token: token,
                    side: side,
                    revealToken: revealToken
                )
            )
            return true
        }
        if previousOffscreenSide != side || context.reassertHidden
            || context.pendingParkWindowIds.contains(token.windowId)
        {
            diff.visibilityChanges.append(.hide(token, side: side))
        }
        return true
    }
}
