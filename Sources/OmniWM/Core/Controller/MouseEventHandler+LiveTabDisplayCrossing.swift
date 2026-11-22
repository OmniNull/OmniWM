// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func tabPullCrossDisplayDrop(_ drop: CrossDisplayDrop, at location: CGPoint) -> CrossDisplayDrop {
        guard let controller else { return drop }
        let placement: CrossDisplayDrop.Placement
        if controller.workspaceManager.activeLayoutKind(for: drop.workspaceId) == .dwindle {
            if let hit = controller.tabRailManager.dragTarget(at: location),
               hit.workspaceId == drop.workspaceId, case .dwindleTile = hit.owner
            {
                placement = .dwindleGroup(target: hit.token, index: hit.visualIndex)
            } else if case let .swap(target) = drop.placement,
                      let tile = controller.dwindleEngine?.tile(containing: target, in: drop.workspaceId)
            {
                placement = .dwindleGroup(target: target, index: tile.activeIndex + 1)
            } else { return drop }
        } else if case let .swap(target) = drop.placement {
            placement = .niriStack(target: target, after: true)
        } else { return drop }
        return CrossDisplayDrop(
            sourceToken: drop.sourceToken, sourceWorkspaceId: drop.sourceWorkspaceId,
            workspaceId: drop.workspaceId, monitor: drop.monitor,
            placement: placement, previewFrame: drop.previewFrame
        )
    }

    func startCrossDisplayTabPull(
        _ pull: inout MouseInputState.CarriedWindow,
        in workspaceId: WorkspaceDescriptor.ID,
        at location: CGPoint,
        holding region: CGRect?
    ) -> Bool {
        guard let controller else { return false }
        let frame = pull.startFrame.offsetBy(
            dx: location.x - pull.anchorLocation.x, dy: location.y - pull.anchorLocation.y
        )
        pull.layout = controller.workspaceManager.activeLayoutKind(for: workspaceId)
        let began: Bool
        var orientation: Monitor.Orientation?
        switch pull.layout {
        case .dwindle:
            guard let engine = controller.dwindleEngine else { return false }
            began = controller.workspaceManager.withEngineMutationScope(in: workspaceId, source: .mouse) {
                guard engine.liveTabMoveBegin(
                    token: pull.token, startLocation: location, holding: region, in: workspaceId
                )
                else { return false }
                engine.liveMoveSetFloatingFrame(frame)
                return true
            }
        case .niri:
            guard let engine = controller.niriEngine, let context = liveColumnContext(for: workspaceId),
                  let window = engine.findNode(for: pull.token, in: workspaceId),
                  let column = engine.findColumn(containing: window, in: workspaceId)
            else { return false }
            began = controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                guard engine.liveColumnMoveBegin(
                    windowId: window.id, windowToken: pull.token, pullsTab: column.isTabbed, canCarry: true,
                    context: context, state: &state
                ) else { return false }
                engine.liveColumnMove?.floatingFrame = frame
                return true
            }
            orientation = context.orientation
        }
        guard began else { return false }
        liveDragSession = .init(carriedWindow: pull)
        if let orientation, let monitor = controller.workspaceManager.monitor(for: workspaceId) {
            holdLiveEdgeZone(startingAt: location, monitorFrame: monitor.frame, orientation: orientation)
        }
        controller.syncLiveDragPointerHold(active: true)
        return true
    }
}
