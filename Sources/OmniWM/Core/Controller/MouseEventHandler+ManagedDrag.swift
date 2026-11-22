// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    private func handleDwindleMoveDrag(at location: CGPoint, on knownMonitor: Monitor? = nil) {
        guard let controller, let engine = controller.dwindleEngine,
              let move = engine.interactiveMove, let startFrame = move.startFrame,
              let monitor = knownMonitor ?? controller.workspaceManager.monitor(for: move.workspaceId),
              let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id),
              workspace.id == move.workspaceId,
              controller.settings.workspaces.layoutType(for: workspace.name) == .dwindle
        else {
            cancelActiveMouseInteraction()
            return
        }
        let frame = startFrame.offsetBy(dx: location.x - move.startLocation.x, dy: location.y - move.startLocation.y)
        guard frame != move.floatingFrame else { return }
        engine.interactiveMove?.floatingFrame = frame
        let refresh = controller.layoutRefreshController
        let geometry = refresh.buildMonitorSnapshot(for: monitor)
        let region = engine.prepareLiveMoveTarget(
            at: location, time: controller.animationClock.now(),
            workspaceFrame: geometry.workingFrame
        )
        guard engine.interactiveMove != nil else {
            cancelActiveMouseInteraction()
            return
        }
        if let region, controller.workspaceManager.withEngineMutationScope(in: workspace.id, source: .mouse, {
            engine.applyLiveMoveTarget(in: region)
        }) {
            controller.workspaceManager.recordLayoutOperation(
                .interactiveMoveEnded(token: move.token),
                in: workspace.id,
                source: .mouse
            )
            refresh.requestImmediateRelayout(
                reason: .interactiveGesture, affectedWorkspaceIds: [workspace.id]
            )
        } else {
            refresh.renderDwindleCarriedWindow(
                in: workspace.id,
                on: monitor,
                geometry: geometry,
                controller: controller
            )
        }
    }

    func finishDwindleMove(at location: CGPoint) {
        handleDwindleMoveDrag(at: location)
        guard state.isMoving, let controller, let engine = controller.dwindleEngine,
              let wsId = engine.liveMoveWorkspaceId
        else { return }
        controller.workspaceManager.withEngineMutationScope(in: wsId, source: .mouse) {
            _ = engine.endCarriedLiveMove(at: controller.animationClock.now())
        }
        restoreManagedMove(in: wsId)
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

    func updateActiveMove(at location: CGPoint, on monitor: Monitor? = nil) {
        if state.moveLayout == .dwindle {
            handleDwindleMoveDrag(at: location, on: monitor)
        } else {
            moveCarriedWindow(to: location)
        }
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
