// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

extension SurfaceReconciler {
    func configureParkingEdgeCallbacks(_ manager: ParkingEdgeMaskManager) {
        manager.canInteract = { [weak self] in
            self?.canInteractWithParkingEdge(isHover: $0) == true
        }
        manager.animationsEnabled = { [weak self] in
            self?.controller?.motionPolicy.animationsEnabled == true
        }
        manager.onActivate = { [weak self] key, navigation in
            self?.activateParkingEdge(key, navigation: navigation)
        }
    }

    private func canInteractWithParkingEdge(isHover: Bool) -> Bool {
        guard let controller, controller.isEnabled, !controller.isOverviewOpen(),
              !controller.mouseEventHandler.isInputSuppressed,
              !controller.mouseEventHandler.isInteractiveGestureActive,
              !controller.mouseEventHandler.isTrackpadSwipeSessionActive
        else { return false }
        guard isHover else { return true }
        guard controller.focusFollowsMouseEnabled,
              controller.focusPolicyEngine.evaluate(.focusFollowsMouse).allowsFocusChange,
              !controller.settings.focus.lockModifier.isHeld(inRawFlags: UInt64(NSEvent.modifierFlags.rawValue))
        else { return false }
        switch controller.workspaceManager.nativeFocusOwner {
        case .ownedSurface: return false
        case .external: return controller.workspaceManager.activeNativeFullscreenFocusOwnerToken != nil
        case .managed,
             .none: return true
        }
    }

    private func activateParkingEdge(_ key: ParkingEdgeMaskKey, navigation: ParkingEdgeNavigation) {
        guard let controller,
              let monitor = controller.workspaceManager.monitors.first(where: { $0.id == key.monitorId }),
              !controller.workspaceManager.hasPendingNativeFullscreenTransition(in: navigation.workspaceId),
              controller.workspaceManager.entry(for: navigation.target)?.workspaceId == navigation.workspaceId,
              let engine = controller.niriEngine
        else { return }
        let columns = engine.projectedColumns(in: navigation.workspaceId)
        let state = controller.workspaceManager.niriViewportState(for: navigation.workspaceId)
        let index = engine.projectedActiveColumnIndex(state: state, columns: columns, in: navigation.workspaceId)
            + key.side.step
        guard columns.indices.contains(index),
              engine.projectedActiveWindow(in: columns[index])?.token == navigation.target
        else { return }
        controller.niriLayoutHandler.focusAdjacentColumn(
            step: key.side.step, in: navigation.workspaceId, on: monitor
        )
    }
}
