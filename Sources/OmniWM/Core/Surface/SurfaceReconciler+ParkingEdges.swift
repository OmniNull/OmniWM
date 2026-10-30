// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension SurfaceReconciler {
    func configureParkingEdgeCallbacks(_ manager: ParkingEdgeMaskManager) {
        manager.canInteract = { [weak self] in
            self?.canInteractWithParkingEdge(isHover: $0) == true
        }
        manager.animationsEnabled = { [weak self] in
            self?.controller?.motionPolicy.animationsEnabled == true
        }
        manager.navigationInterval = { [weak self] in
            self?.controller?.settings.focus.edgeNavigationInterval ?? SettingsExport.Focus.defaults()
                .edgeNavigationInterval
        }
        manager.onActivate = { [weak self] key, navigation in
            self?.activateParkingEdge(key, navigation: navigation) == true
        }
    }

    func pointerEdgeFinSpans() -> [ParkingEdgeMaskKey: CGRect] {
        guard let monitors = controller?.workspaceManager.monitors, canInteractWithParkingEdge(isHover: false) else {
            return [:]
        }
        var spans: [ParkingEdgeMaskKey: CGRect] = [:]
        for mask in appliedScene.parkingEdgeMasks where mask.navigation != nil {
            guard let frame = monitors.first(where: { $0.id == mask.key.monitorId })?.frame else { continue }
            let reachesEdge = switch mask.key.side {
            case .left: mask.frame.minX == frame.minX
            case .right: mask.frame.maxX == frame.maxX
            case .top: mask.frame.maxY == frame.maxY
            case .bottom: mask.frame.minY == frame.minY
            }
            if reachesEdge {
                spans[mask.key] = mask.frame
            }
        }
        return spans
    }

    private func canInteractWithParkingEdge(isHover: Bool) -> Bool {
        guard let controller, controller.isEnabled, !controller.isOverviewOpen(),
              !controller.mouseEventHandler.isInputSuppressed,
              !controller.mouseEventHandler.isInteractiveGestureActive,
              !controller.mouseEventHandler.isTrackpadSwipeSessionActive
        else { return false }
        guard isHover else { return true }
        guard controller.focusFollowsMouseEnabled,
              !controller.settings.focus.followsMouseOnlyFullyVisible,
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

    private func activateParkingEdge(_ key: ParkingEdgeMaskKey, navigation: ParkingEdgeNavigation) -> Bool {
        guard let controller,
              let monitor = controller.workspaceManager.monitors.first(where: { $0.id == key.monitorId }),
              !controller.workspaceManager.hasPendingNativeFullscreenTransition(in: navigation.workspaceId),
              controller.workspaceManager.entry(for: navigation.target)?.workspaceId == navigation.workspaceId,
              let engine = controller.niriEngine
        else { return false }
        let columns = engine.projectedColumns(in: navigation.workspaceId)
        let state = controller.workspaceManager.niriViewportState(for: navigation.workspaceId)
        let index = engine.projectedActiveColumnIndex(state: state, columns: columns, in: navigation.workspaceId)
            + key.side.step
        guard columns.indices.contains(index),
              engine.projectedActiveWindow(in: columns[index])?.token == navigation.target
        else { return false }
        return controller.niriLayoutHandler.focusAdjacentColumn(
            step: key.side.step, in: navigation.workspaceId, on: monitor
        )
    }
}
