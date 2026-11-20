// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    struct DwindlePressHit {
        let token: WindowToken
        let zone: FusionDoubleClickZone?
    }

    func dwindlePressHit(at location: CGPoint, in workspaceId: WorkspaceDescriptor.ID) -> DwindlePressHit? {
        guard let controller, let engine = controller.dwindleEngine else { return nil }
        let now = controller.animationClock.now()
        guard let token = engine.hitTestFocusableWindow(point: location, in: workspaceId, at: now),
              let entry = controller.workspaceManager.entry(for: token),
              entry.workspaceId == workspaceId, entry.mode == .tiling
        else { return nil }
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId),
              let frame = engine.presentedFrame(for: token, in: workspaceId, at: now),
              let zone = NiriLayoutEngine.fusionDoubleClickZone(
                  at: location, in: frame, gap: 0, bounds: monitor.visibleFrame
              ),
              canHandleManagedMouseInteraction(controller: controller),
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .dwindle,
              entry.layoutReason == .standard, entry.hiddenState == nil,
              !entry.observedState.isNativeSuppressed,
              !controller.axManager.macOSHiddenAppPIDs.contains(token.pid),
              !controller.axManager.isWindowNativeSuppressed(token),
              !hasPendingNativeFullscreenTransition(at: location),
              !isPointerDisplayShowingFullscreenSpace(at: location)
        else { return DwindlePressHit(token: token, zone: nil) }
        return DwindlePressHit(token: token, zone: zone)
    }

    func handleDwindleDoubleClick(at location: CGPoint, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller,
              let hit = dwindlePressHit(at: location, in: workspaceId), let zone = hit.zone,
              topmostWindowIdProvider(location) == hit.token.windowId
        else { return false }
        switch zone {
        case .titleBar:
            guard TitleBarHitTest.isTitleBar(titleBarHitProvider(hit.token.pid, location)),
                  controller.dwindleLayoutHandler.toggleFullscreen(for: hit.token, in: workspaceId)
            else { return false }
        case let .edge(edge):
            guard controller.dwindleLayoutHandler.toggleEdgeExpansion(for: hit.token, edge: edge, in: workspaceId)
            else { return false }
        }
        clearNativeTitleBarDrag()
        controller.noteUserAction()
        tapInputs.capturedInteractionButton = .left
        return true
    }
}
