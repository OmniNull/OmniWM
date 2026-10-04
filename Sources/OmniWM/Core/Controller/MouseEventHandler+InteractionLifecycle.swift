// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    var isTrackpadSwipeSessionActive: Bool {
        state.gesturePhase != .idle
    }

    var isViewportGestureActive: Bool {
        switch state.gesturePhase {
        case .idle:
            false
        case .armed:
            state.lockedGestureContext?.columnScrollCandidate == true
        case .committed:
            state.activeGestureMode == .columnScroll
        }
    }

    var isInteractiveGestureActive: Bool {
        state.isMoving || state.isResizing || isViewportGestureActive
    }

    func handleExpiredViewportGesture(
        in workspaceId: WorkspaceDescriptor.ID,
        sessionID: AnimationDriver.GestureSessionID
    ) {
        terminateViewportGesture(
            in: workspaceId,
            sessionID: sessionID,
            disposition: .viewportAlreadySettled
        )
    }

    @discardableResult
    func terminateViewportGesture(
        in workspaceId: WorkspaceDescriptor.ID,
        sessionID: AnimationDriver.GestureSessionID,
        disposition: ViewportGestureTerminationDisposition
    ) -> Bool {
        guard state.gesturePhase == .committed,
              state.lockedGestureContext?.workspaceId == workspaceId,
              state.activeGestureMode == .columnScroll,
              state.viewportGestureSessionID == sessionID
        else { return false }
        let liveSessionID = controller?.workspaceManager.animationDriver.gestureSessionID(in: workspaceId)
        guard liveSessionID == sessionID || disposition == .viewportAlreadySettled && liveSessionID == nil else {
            return false
        }
        retainConsumedTrackpadSession()
        switch disposition {
        case .settleLiveOffset:
            cancelCommittedGestureViewportState(for: workspaceId)
        case .settleLiveOffsetWithoutRelayout:
            cancelCommittedGestureViewportState(for: workspaceId, requestRelayout: false)
        case .viewportAlreadySettled:
            break
        }
        if disposition != .viewportAlreadySettled {
            state.suppressGestureStartUntilAllTouchesLift = true
            state.consumeTrackpadScrollUntilAllTouchesLift = true
            state.suppressTrackpadMomentumScroll = true
        }
        resetGestureState(settleViewportGesture: false)
        return true
    }

    func handleInputSuppressionBegan() {
        state.latestFocusFollowsMouseSample = nil
        clearNativeTitleBarDrag()
        cancelActiveMouseInteraction()
        dropPendingTapEvents()
        resetMouseWheelTrackers()
        abortActiveGestureIfNeeded()
        clearGestureLatches()
        clearConsumedTrackpadSessions()
    }

    func handleAppVisibilityChanged() {
        state.latestFocusFollowsMouseSample = nil
        clearNativeTitleBarDrag()
        cancelActiveMouseInteraction()
        dropPendingTapEvents()
        resetMouseWheelTrackers()
        abortActiveGestureIfNeeded()
        clearGestureLatches()
    }

    func resetMouseWheelTrackers() {
        state.horizontalWheelTracker.reset()
        state.verticalWheelTracker.reset()
    }

    func cancelActiveMouseInteraction() {
        guard let controller else { return }
        let wasActive = state.isMoving || state.isResizing

        if state.isMoving {
            controller.niriEngine?.interactiveMoveCancel()
            controller.dwindleEngine?.interactiveMoveCancel()
            clearMoveInteractionState()
        }

        if state.isResizing {
            finishActiveResize()
            clearResizeInteractionState()
        }

        resetHoveredEdgesIfNeeded()
        if wasActive {
            NSCursor.arrow.set()
        }
    }

    func recoverAfterTapDisable() {
        cancelActiveMouseInteraction()
        let pressedButtons = pressedMouseButtonsProvider()
        if pressedButtons & MouseButton.left.pressedMask == 0 {
            finishNativeTitleBarDragIfNeeded(button: .left)
        }
        if let button = state.capturedInteractionButton, pressedButtons & button.pressedMask == 0 {
            state.capturedInteractionButton = nil
        }
        if let button = state.capturedOtherMouseButton, pressedButtons & (1 << Int(button)) == 0 {
            state.capturedOtherMouseButton = nil
        }
    }

    private func finishActiveResize() {
        if state.resizeLayout == .dwindle {
            finishDwindleResize()
        } else {
            finishNiriResize()
        }
    }

    private func finishDwindleResize() {
        guard let controller, let engine = controller.dwindleEngine else { return }
        let workspaceId = engine.interactiveResize?.workspaceId
        guard engine.interactiveResizeEnd(), let workspaceId else { return }
        controller.workspaceManager.recordLayoutOperation(.splitRatioChanged, in: workspaceId, source: .mouse)
        if controller.hasStartedServices {
            controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
        }
    }

    private func finishNiriResize() {
        guard let controller, let engine = controller.niriEngine, let resize = engine.interactiveResize else { return }
        let workspaceId = resize.workspaceId
        let resizedToken = (engine.findNode(by: resize.windowId, in: workspaceId) as? NiriWindow)?.token
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId), let resizedToken else {
            engine.clearInteractiveResize()
            return
        }
        let geometry = controller.niriInteractionGeometry(for: monitor)
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { viewportState in
            engine.interactiveResizeEnd(
                motion: controller.motionPolicy.snapshot(),
                state: &viewportState,
                workingFrame: geometry.workingFrame,
                gaps: geometry.innerGap
            )
        }
        controller.workspaceManager.recordLayoutOperation(
            .interactiveResizeEnded(token: resizedToken),
            in: workspaceId,
            source: .mouse
        )
        if controller.workspaceManager.animationDriver.hasMotion(in: workspaceId) {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        } else if controller.hasStartedServices {
            controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
        }
    }

    func resetHoveredEdgesIfNeeded() {
        if !state.currentHoveredEdges.isEmpty {
            NSCursor.arrow.set()
            state.currentHoveredEdges = []
        }
    }

    func handleMouseUpFromTap(at location: CGPoint, button: MouseButton) {
        guard let controller else { return }
        if controller.isOverviewOpen() {
            cancelActiveMouseInteraction()
            return
        }
        if state.isMoving {
            guard shouldAcceptInteractionButton(button) else { return }
            completeActiveMove(at: location)
            return
        }

        guard state.isResizing else { return }
        guard shouldAcceptInteractionButton(button) else { return }
        completeActiveResize()
    }

    func clearMoveInteractionState() {
        state.dragGhostController?.endDrag()
        state.isMoving = false
        state.moveLayout = nil
        state.activeInteractionSource = nil
    }

    func clearResizeInteractionState() {
        state.isResizing = false
        state.activeInteractionSource = nil
        state.resizeLayout = nil
        state.currentHoveredEdges = []
    }

    func completeActiveMove(at location: CGPoint) {
        if state.moveLayout == .dwindle {
            finishDwindleMove()
        } else {
            finishNiriMove(at: location)
        }
        clearMoveInteractionState()
        NSCursor.arrow.set()
    }

    func completeActiveResize() {
        finishActiveResize()
        clearResizeInteractionState()
        NSCursor.arrow.set()
    }
}
