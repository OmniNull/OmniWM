// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    private func handleDwindleMoveDrag(at location: CGPoint) {
        guard let controller, let engine = controller.dwindleEngine,
              let move = engine.interactiveMove,
              let startFrame = move.startFrame,
              let monitor = controller.workspaceManager.monitor(for: move.workspaceId)
        else {
            cancelActiveMouseInteraction()
            return
        }
        let frame = startFrame.offsetBy(
            dx: location.x - move.startLocation.x, dy: location.y - move.startLocation.y
        )
        guard frame != move.floatingFrame else { return }
        engine.interactiveMove?.floatingFrame = frame
        let now = controller.animationClock.now()
        _ = engine.interactiveMoveUpdate(
            currentLocation: location, at: now,
            workspaceFrame: controller.insetWorkingFrame(for: monitor)
        )
        guard engine.interactiveMove != nil else {
            cancelActiveMouseInteraction()
            return
        }
        _ = controller.dwindleLayoutHandler.applyFramesOnDemand(workspaceId: move.workspaceId, monitor: monitor)
    }

    func finishDwindleMove(at location: CGPoint) {
        guard let controller, let engine = controller.dwindleEngine else { return }
        guard let wsId = engine.interactiveMove?.workspaceId else {
            restoreManagedMove(in: state.lockedGestureContext?.workspaceId)
            return
        }
        guard let monitor = controller.workspaceManager.monitor(for: wsId) else {
            engine.interactiveMoveCancel()
            restoreManagedMove(in: wsId)
            return
        }
        _ = engine.interactiveMoveUpdate(
            currentLocation: location, at: controller.animationClock.now(),
            workspaceFrame: controller.insetWorkingFrame(for: monitor)
        )
        guard let move = engine.interactiveMove, move.target != nil else {
            engine.interactiveMoveCancel()
            restoreManagedMove(in: wsId)
            return
        }
        let changed = controller.workspaceManager.withEngineMutationScope(
            in: wsId,
            label: move.isInsertion ? "dwindle_mouse_insert" : "dwindle_mouse_swap",
            source: .mouse
        ) {
            engine.interactiveMoveEnd() != nil
        }
        guard changed else {
            restoreManagedMove(in: wsId)
            return
        }
        controller.workspaceManager.recordLayoutOperation(
            move.isInsertion ? .interactiveMoveEnded(token: move.token) : .windowsSwapped,
            in: wsId,
            source: .mouse
        )
        if controller.hasStartedServices {
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .interactiveGesture, affectedWorkspaceIds: [wsId]
            )
        }
    }

    func finishNiriMove(at location: CGPoint) {
        guard let controller else { return }
        guard let engine = controller.niriEngine, let move = engine.interactiveMove else {
            controller.niriEngine?.interactiveMoveCancel()
            restoreManagedMove(in: state.lockedGestureContext?.workspaceId)
            return
        }
        let wsId = move.workspaceId
        guard let monitor = controller.workspaceManager.monitor(for: wsId) else {
            engine.interactiveMoveCancel()
            restoreManagedMove(in: wsId)
            return
        }
        let geometry = controller.niriInteractionGeometry(for: monitor)
        let movedToken = move.windowToken
        var didEnd = false
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            didEnd = engine.interactiveMoveEnd(
                at: location,
                motion: controller.motionPolicy.snapshot(),
                state: &vstate,
                workingFrame: geometry.workingFrame,
                gaps: geometry.innerGap
            )
        }
        guard didEnd else {
            restoreManagedMove(in: wsId)
            return
        }
        controller.workspaceManager.recordLayoutOperation(
            .interactiveMoveEnded(token: movedToken),
            in: wsId,
            source: .mouse
        )
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .interactiveGesture, affectedWorkspaceIds: [wsId]
        )
    }

    func handleMouseDraggedFromTap(
        at location: CGPoint,
        button: MouseButton,
        requirePressedButtonCheck: Bool = true
    ) {
        guard let controller else { return }
        guard canHandleManagedMouseInteraction(controller: controller) else { return }
        guard !state.gestureOwnsWindowInteraction else { return }
        if requirePressedButtonCheck {
            guard pressedMouseButtonsProvider() & button.pressedMask != 0 else {
                cancelActiveMouseInteraction()
                return
            }
        }

        if state.isMoving {
            guard shouldAcceptInteractionButton(button) else { return }
            updateActiveMove(at: location)
            return
        }

        if trackLiveColumnDrag(at: location, button: button) { return }

        guard state.isResizing else { return }
        guard shouldAcceptInteractionButton(button) else { return }

        updateManagedResize(at: location)
    }

    func canHandleManagedMouseInteraction(controller: WMController) -> Bool {
        guard controller.isEnabled else {
            cancelActiveMouseInteraction()
            return false
        }
        if controller.isOverviewOpen() {
            cancelActiveMouseInteraction()
            return false
        }

        return true
    }

    func updateActiveMove(at location: CGPoint) {
        if state.moveLayout == .dwindle {
            handleDwindleMoveDrag(at: location)
        } else {
            updateNiriMove(at: location)
        }
    }

    private func updateNiriMove(at location: CGPoint) {
        guard let controller else { return }
        guard let engine = controller.niriEngine, let move = engine.interactiveMove,
              let startFrame = move.startFrame
        else {
            cancelActiveMouseInteraction()
            return
        }
        let frame = startFrame.offsetBy(
            dx: location.x - move.startMouseLocation.x, dy: location.y - move.startMouseLocation.y
        )
        guard frame != move.floatingFrame else { return }
        engine.interactiveMove?.floatingFrame = frame
        _ = engine.interactiveMoveUpdate(currentLocation: location)
        guard engine.interactiveMove != nil else {
            cancelActiveMouseInteraction()
            return
        }
        controller.layoutRefreshController.renderInteractiveResize(for: move.workspaceId)
    }

    func restoreManagedMove(in workspaceId: WorkspaceDescriptor.ID?) {
        guard let workspaceId, let controller,
              controller.workspaceManager.descriptor(for: workspaceId) != nil
        else { return }
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .interactiveGesture, affectedWorkspaceIds: [workspaceId]
        )
    }

    func updateManagedResize(at location: CGPoint) {
        guard let controller else { return }
        if state.resizeLayout == .dwindle {
            guard let engine = controller.dwindleEngine,
                  let wsId = engine.interactiveResize?.workspaceId
            else {
                cancelActiveMouseInteraction()
                return
            }
            if engine.interactiveResizeUpdate(currentLocation: location) {
                controller.layoutRefreshController.renderDwindleInteractiveResize(for: wsId)
            }
            return
        }

        guard let engine = controller.niriEngine,
              let resize = engine.interactiveResize,
              let monitor = controller.workspaceManager.monitor(for: resize.workspaceId)
        else {
            cancelActiveMouseInteraction()
            return
        }

        let geometry = controller.niriInteractionGeometry(for: monitor)
        let gaps = LayoutGaps(
            horizontal: geometry.innerGap,
            vertical: geometry.innerGap
        )
        let wsId = resize.workspaceId

        if engine.interactiveResizeUpdate(
            currentLocation: location,
            monitorFrame: geometry.workingFrame,
            gaps: gaps,
            viewportState: { mutate in
                controller.workspaceManager.withNiriViewportState(for: wsId, mutate)
            }
        ) {
            controller.layoutRefreshController.renderInteractiveResize(for: wsId)
        }
    }
}
