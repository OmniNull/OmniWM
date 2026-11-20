// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func handleTabRailDrag(_ drag: TabRailDrag) {
        if case .dwindleTile = drag.info.owner {
            beginLiveDwindleTabPull(drag)
        } else {
            beginLiveNiriTabPull(drag)
        }
    }

    private func beginLiveNiriTabPull(_ drag: borrowing TabRailDrag) {
        guard let token = drag.token,
              !isLiveColumnDragActive,
              liveDragSession?.tabPull == nil,
              let controller,
              let entry = controller.workspaceManager.entry(for: token),
              controller.isNiriStrip(entry.workspaceId),
              let engine = controller.niriEngine,
              let context = liveColumnContext(for: entry.workspaceId),
              let window = engine.findNode(for: token, in: entry.workspaceId),
              let column = engine.findColumn(containing: window, in: entry.workspaceId)
        else { return }
        finishPendingLiveStackDrop()
        let viewport = controller.workspaceManager.niriViewportState(for: entry.workspaceId)
        guard let startFrame = engine.liveWindowFrame(of: window, in: column, context: context, state: viewport)
            ?? entry.axRef.flatMap(nativeWindowFrameProvider)
        else { return }

        let layoutStart = controller.niriLayoutHandler
            .layoutChangeStartCoveringEveryNiriWorkspace(in: entry.workspaceId)
        let began = controller.workspaceManager.withNiriViewportState(for: entry.workspaceId) { viewportState in
            engine.liveColumnMoveBegin(
                windowId: window.id,
                windowToken: token,
                pullsTab: true,
                context: context,
                state: &viewportState
            )
        }
        guard began else { return }
        state.liveDragLayoutStart = layoutStart
        liveDragSession = .init(tabPull: .init(token: token, anchorLocation: drag.location, startFrame: startFrame))
        if let monitor = controller.workspaceManager.monitor(for: entry.workspaceId) {
            holdLiveEdgeZone(startingAt: drag.location, monitorFrame: monitor.frame, orientation: context.orientation)
        }
        state.deferredClickScroll = nil
        controller.syncLiveDragPointerHold(active: true)
        let location = drag.location
        let towardTrailingSide = context.primaryCoordinate(of: location)
            >= context.primaryCoordinate(of: drag.pressLocation)
        let detached = controller.workspaceManager.withNiriViewportState(for: entry.workspaceId) { viewportState in
            engine.liveColumnMoveDetachTab(
                towardTrailingSide: towardTrailingSide,
                cursor: location,
                context: context,
                state: &viewportState
            )
        }
        if detached {
            engine.liveColumnMoveSettled()
        }
        moveLiveTabPull(to: drag.location)
    }

    func moveLiveTabPull(to location: CGPoint) {
        if liveDragSession?.tabPull?.layout == .dwindle {
            moveLiveDwindleTabPull(to: location)
            return
        }
        guard let pull = liveDragSession?.tabPull,
              let controller,
              let engine = controller.niriEngine,
              engine.liveColumnMove?.windowToken == pull.token
        else { return }
        let frame = pull.startFrame.offsetBy(
            dx: location.x - pull.anchorLocation.x,
            dy: location.y - pull.anchorLocation.y
        )
        guard engine.liveColumnMove?.floatingFrame != frame else { return }
        engine.liveColumnMove?.floatingFrame = frame
        livePointer.location = location
        recordLivePointerSample(location)
        updateLiveColumnDrag(at: location)
        guard liveDragSession?.tabPull?.layout == .niri else { return }
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .interactiveGesture,
            affectedWorkspaceIds: Set([engine.liveColumnMove?.workspaceId].compactMap(\.self))
        )
    }

    func endLiveTabPull(at location: CGPoint) {
        guard liveDragSession?.tabPull != nil else { return }
        moveLiveTabPull(to: location)
        guard let pull = liveDragSession?.tabPull, let controller else { return }
        if liveCrossDisplayMove != nil {
            let frame = pull.layout == .dwindle ? controller.dwindleEngine?.liveTabMoveFloatingFrame
                : controller.niriEngine?.liveColumnMove?.floatingFrame
            _ = finishLiveCrossDisplayMove(token: pull.token, releaseFrame: frame)
            if pull.layout == .dwindle { endLiveDragSession() }
            return
        }
        if pull.layout == .dwindle {
            finishLiveDwindleTabPull()
            return
        }
        guard let engine = controller.niriEngine else { return }
        let released = engine.liveColumnMove?.floatingFrame
        _ = finishLiveColumnDrag(token: pull.token, releaseFrame: released)
    }
}
