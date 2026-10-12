// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

@MainActor func hasPendingNiriAnimationWork(
    state: ViewportState,
    driver: AnimationDriver,
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID
) -> Bool {
    state.hasPendingOffsetAnimation
        || driver.hasMotion(in: workspaceId)
        || engine.hasAnyWindowAnimationsRunning(in: workspaceId)
        || engine.hasAnyColumnAnimationsRunning(in: workspaceId)
}

struct StructuralMutation: Equatable {
    let sourceWorkspaceId: WorkspaceDescriptor.ID
    let destinationWorkspaceId: WorkspaceDescriptor.ID
    let selectedHandle: WindowHandle
    let movedTokens: [WindowToken]
    let scrollWorkspaceId: WorkspaceDescriptor.ID?

    var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> {
        if sourceWorkspaceId == destinationWorkspaceId {
            return [sourceWorkspaceId]
        }
        return [sourceWorkspaceId, destinationWorkspaceId]
    }
}

enum StructuralMutationOutcome: Equatable {
    case changed(StructuralMutation)
    case atWorkspaceEdge
    case unchanged

    var mutation: StructuralMutation? {
        guard case let .changed(mutation) = self else { return nil }
        return mutation
    }

    var didMutate: Bool {
        mutation != nil
    }
}

@MainActor final class NiriLayoutHandler {
    weak var controller: WMController?

    struct NiriLayoutPass {
        let motion: MotionSnapshot
        let wsId: WorkspaceDescriptor.ID
        let engine: NiriLayoutEngine
        let monitor: Monitor
        let orientation: Monitor.Orientation
        let insetFrame: CGRect
        let gap: CGFloat
        let windows: [LayoutWindowSnapshot]
        let windowTokens: [WindowToken]

        var interactionContext: NiriInteractionContext {
            NiriInteractionContext(
                workspaceId: wsId, motion: motion, workingFrame: insetFrame,
                gaps: gap, orientation: orientation
            )
        }

        var primarySpanKeyPath: KeyPath<NiriContainer, CGFloat> {
            switch orientation {
            case .horizontal: \.cachedWidth
            case .vertical: \.cachedHeight
            }
        }
    }

    struct RemovalContext {
        var existingHandleIds: Set<WindowToken>
        var wasEmptyBeforeSync: Bool
        var removalResult: NiriLayoutEngine.NiriRemovalResult
        var externallyRemovedColumn: Bool

        var removedColumn: Bool {
            externallyRemovedColumn || !removalResult.removedColumnIndicesBefore.isEmpty
        }
    }

    struct InsertionContext {
        var newTokens: [WindowToken]
        var tabLocalTokens: Set<WindowToken>
        var viewOriginBeforeInsertion: CGFloat?
    }

    struct ArrivalContext {
        var activateWindowToken: WindowToken?
        var rememberedFocusToken: WindowToken?
        var hasNewWindowArrival: Bool
        var shouldStartScrollForNewWindow: Bool
    }

    struct NiriStructuralMutation {
        let movedTokens: [WindowToken]
        let operation: LayoutOperation
    }

    enum ColumnMoveTarget {
        case direction(Direction)
        case first
        case last
        case index(Int)
    }

    var scrollAnimationByDisplay: [CGDirectDisplayID: WorkspaceDescriptor.ID] = [:]

    init(controller: WMController?) {
        self.controller = controller
    }

    func requestLayoutCommandRelayout(
        in workspaceId: WorkspaceDescriptor.ID,
        postLayout: LayoutRefreshController.PostLayoutAction? = nil
    ) {
        controller?.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [workspaceId],
            postLayout: postLayout,
            postLayoutDomains: .layoutCommit
        )
    }

    func recordLayoutOperation(
        _ operation: LayoutOperation,
        in workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
    ) {
        controller?.workspaceManager.recordLayoutOperation(operation, in: workspaceId, source: source)
    }

    func focusSelectedWindowAndRequestRelayout(
        in workspaceId: WorkspaceDescriptor.ID,
        raisesWindow: Bool = true,
        defersRetryRaise: Bool = false
    ) {
        guard let controller else { return }
        let viewportState = controller.workspaceManager.niriViewportState(for: workspaceId)
        if let selectedNodeId = viewportState.selectedNodeId,
           let selectedWindow = controller.niriEngine?.findNode(
               by: selectedNodeId,
               in: workspaceId
           ) as? NiriWindow,
           controller.workspaceManager.entry(for: selectedWindow.token)?.workspaceId == workspaceId,
           !controller.isManagedWindowSuppressedByMacOS(selectedWindow.token)
        {
            controller.focusWindow(
                selectedWindow.token,
                raisesWindow: raisesWindow,
                defersRetryRaise: defersRetryRaise,
                requiresWorkerRaise: !raisesWindow && defersRetryRaise
                    && hasFullscreenOverlap(with: selectedWindow, in: workspaceId)
            )
        }
        requestLayoutCommandRelayout(in: workspaceId)
    }

    private func hasFullscreenOverlap(
        with selectedWindow: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller,
              let root = controller.niriEngine?.root(for: workspaceId),
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              let selectedFrame = selectedWindow.renderedFrame,
              controller.isManagedWindowDisplayable(selectedWindow.token)
        else { return false }
        let visibleSelectedFrame = selectedFrame.intersection(monitor.frame)
        guard !visibleSelectedFrame.isEmpty else { return false }

        return root.allWindows.contains { window in
            guard window !== selectedWindow,
                  selectedWindow.isFullscreen || window.isFullscreen,
                  let entry = controller.workspaceManager.entry(for: window.token),
                  entry.workspaceId == workspaceId,
                  entry.mode == .tiling,
                  entry.layoutReason == .standard,
                  entry.hiddenState == nil,
                  !controller.workspaceManager.isWindowSuppressedByMacOS(entry),
                  let frame = window.renderedFrame
            else { return false }
            return frame.intersects(visibleSelectedFrame)
        }
    }

    func activatePointerHoveredWindow(
        _ window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller, let engine = controller.niriEngine else { return }
        var shouldStartScrollAnimation = false
        var shouldRequestRelayout = false

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            activateNode(
                window,
                in: workspaceId,
                state: &state,
                options: .init(
                    layoutRefresh: false,
                    axFocus: false,
                    startAnimation: false
                )
            )
            shouldStartScrollAnimation = state.hasPendingOffsetAnimation
            shouldRequestRelayout = state.offsetTransition.kind == .jump
        }

        controller.focusWindow(window.token, origin: .focusFollowsMouse)

        if shouldStartScrollAnimation {
            startScrollAnimationIfNeeded(
                for: workspaceId,
                state: controller.workspaceManager.niriViewportState(for: workspaceId),
                engine: engine
            )
        } else if shouldRequestRelayout {
            requestLayoutCommandRelayout(in: workspaceId)
        }
    }
}

struct NodeActivationOptions {
    var activateWindow: Bool = true
    var ensureVisible: Bool = true
    var preserveViewportAnchor: Bool = false
    var updateTimestamp: Bool = true
    var layoutRefresh: Bool = true
    var axFocus: Bool = true
    var focusOrigin: ManagedFocusOrigin = .keyboardOrProgrammatic
    var startAnimation: Bool = true
}

@MainActor struct NiriOperationContext {
    let controller: WMController
    let engine: NiriLayoutEngine
    let motion: MotionSnapshot
    let wsId: WorkspaceDescriptor.ID
    let windowNode: NiriWindow
    let monitor: Monitor
    let orientation: Monitor.Orientation
    let workingFrame: CGRect
    let gaps: CGFloat

    func interactionContext(motion: MotionSnapshot) -> NiriInteractionContext {
        NiriInteractionContext(
            workspaceId: wsId, motion: motion, workingFrame: workingFrame,
            gaps: gaps, orientation: orientation
        )
    }

    func preparePredictedAnimation(
        state: ViewportState,
        oldFrames: [WindowToken: CGRect],
        yContainmentFrame: CGRect? = nil
    ) {
        let scale = NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?
            .backingScaleFactor ?? 2.0
        let layoutFrames = controller.layoutFrames(for: monitor, scale: scale)
        let workingArea = WorkingAreaContext(
            workingFrame: workingFrame,
            singleWindowFrame: layoutFrames.workingFrame,
            borderSafeFillFrame: layoutFrames.borderSafeFillFrame,
            fullscreenLayoutFrame: layoutFrames.fullscreenLayoutFrame,
            viewFrame: monitor.frame,
            scale: scale
        )
        let layoutGaps = LayoutGaps(
            horizontal: gaps,
            vertical: gaps
        )
        let animationTime = (engine.animationClock?.now() ?? CACurrentMediaTime()) + 2.0
        let newFrames = engine.calculateCombinedLayoutUsingPools(
            in: wsId,
            monitor: monitor,
            gaps: layoutGaps,
            state: state,
            workingArea: workingArea,
            animationTime: animationTime
        ).frames
        _ = engine.triggerMoveAnimations(
            in: wsId,
            oldFrames: oldFrames,
            newFrames: newFrames,
            motion: motion,
            yContainmentFrame: yContainmentFrame
        )
    }

    func prepareCapturedAnimation(oldFrames: [WindowToken: CGRect]) {
        let newFrames = engine.captureWindowFrames(in: wsId)
        _ = engine.triggerMoveAnimations(
            in: wsId,
            oldFrames: oldFrames,
            newFrames: newFrames,
            motion: motion
        )
    }
}

extension NiriLayoutHandler: LayoutSizable {}
