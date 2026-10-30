// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    var isLiveEdgeScrolling: Bool {
        state.liveEdgeScroll?.isScrolling == true
    }

    func trackLiveEdgeZone(at location: CGPoint, monitorFrame: CGRect) {
        guard let edge = liveEdgeZone(containing: location, monitorFrame: monitorFrame) else {
            clearLiveEdgeZone()
            return
        }
        if let hold = state.liveEdgeZoneHold, hold.edge == edge, !hold.isPassed(by: location) { return }
        state.liveEdgeZoneHold = nil
        guard state.liveEdgeScroll?.edge != edge else { return }
        endLiveEdgeScroll()
        guard let engine = controller?.niriEngine, let workspaceId = engine.liveColumnMove?.workspaceId else { return }
        let timer = scheduleLiveDragTimer(after: engine.moveConfiguration.liveEdgeScrollDelay) { [weak self] in
            self?.startLiveEdgeScrollIfDue()
        }
        state.liveEdgeScroll = .init(
            edge: edge,
            workspaceId: workspaceId,
            enteredAt: liveDragClock(),
            delayTimer: timer
        )
    }

    func holdLiveEdgeZone(startingAt location: CGPoint, monitorFrame: CGRect) {
        state.liveEdgeZoneHold = liveEdgeZone(containing: location, monitorFrame: monitorFrame)
            .map { .init(edge: $0, x: location.x) }
    }

    func startLiveEdgeScrollIfDue() {
        guard var edgeScroll = state.liveEdgeScroll,
              !edgeScroll.isScrolling,
              isLiveColumnDragActive,
              let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              move.phase == .dragging,
              liveDragClock() - edgeScroll.enteredAt >= engine.moveConfiguration.liveEdgeScrollDelay - 0.005,
              let context = liveColumnContext(for: move.workspaceId)
        else { return }

        let workspaceId = move.workspaceId
        guard let limit = engine.liveEdgeScrollLimit(
            towardTrailingEdge: edgeScroll.edge == .trailing,
            context: context,
            state: controller.workspaceManager.niriViewportState(for: workspaceId)
        ) else { return }
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { viewportState in
            viewportState.edgeScrollOffset(to: limit, speed: engine.moveConfiguration.liveEdgeScrollSpeed)
        }
        edgeScroll.isScrolling = true
        edgeScroll.strip = nil
        state.liveEdgeScroll = edgeScroll
        controller.layoutRefreshController.startScrollAnimation(for: workspaceId, forGesture: true)
    }

    func handleLiveEdgeScrollTick(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) {
        guard isLiveEdgeScrolling,
              let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              move.workspaceId == workspaceId,
              let location = state.liveDragLocation
        else { return }

        guard !controller.workspaceManager.animationDriver.hasEdgeScroll(in: workspaceId)
            || liveEdgeScrollReachesColumn(at: location, time: time, engine: engine, workspaceId: workspaceId)
        else { return }
        stopLiveEdgeScroll(at: time)
        updateLiveColumnDrag(at: location, immediate: true)
    }

    func liveEdgeScrollReachesColumn(
        at location: CGPoint,
        time: TimeInterval,
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller else { return false }
        var probe = controller.workspaceManager.niriViewportState(for: workspaceId)
        probe.viewOffset = controller.workspaceManager.animationDriver.liveViewOffset(
            in: workspaceId,
            semanticOffset: probe.viewOffset,
            at: time
        ) ?? probe.viewOffset
        guard let strip = liveEdgeScrollStrip(at: probe, engine: engine, workspaceId: workspaceId) else { return false }
        return engine.liveColumnMoveWouldChange(cursor: location, strip: strip.columns, context: strip.context)
    }

    private func liveEdgeScrollStrip(
        at viewport: ViewportState,
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID
    ) -> (columns: [LiveColumnMove.StripColumn], context: NiriInteractionContext)? {
        if let cached = state.liveEdgeScroll?.strip, let context = state.liveEdgeScroll?.stripContext {
            let shift = cached.viewOffset - viewport.viewOffset
            let columns = cached.columns.map { LiveColumnMove.StripColumn(
                column: $0.column,
                minX: $0.minX + shift,
                maxX: $0.maxX + shift
            ) }
            return (columns, context)
        }
        guard let context = liveColumnContext(for: workspaceId) else { return nil }
        let columns = engine.liveColumnStrip(context: context, state: viewport)
        state.liveEdgeScroll?.strip = (columns, viewport.viewOffset)
        state.liveEdgeScroll?.stripContext = context
        return (columns, context)
    }

    func stopLiveEdgeScroll(at time: TimeInterval = CACurrentMediaTime()) {
        guard let workspaceId = state.liveEdgeScroll?.workspaceId, isLiveEdgeScrolling else { return }
        state.liveEdgeScroll?.isScrolling = false
        guard let controller else { return }
        let driver = controller.workspaceManager.animationDriver
        guard driver.hasEdgeScroll(in: workspaceId) else { return }
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { viewportState in
            let live = driver.liveViewOffset(in: workspaceId, semanticOffset: viewportState.viewOffset, at: time)
            viewportState.jumpOffset(to: live ?? viewportState.viewOffset)
        }
    }

    func clearLiveEdgeZone() {
        state.liveEdgeZoneHold = nil
        endLiveEdgeScroll()
    }

    func endLiveEdgeScroll() {
        stopLiveEdgeScroll()
        state.liveEdgeScroll?.delayTimer?.invalidate()
        state.liveEdgeScroll = nil
    }

    private func liveEdgeZone(
        containing location: CGPoint,
        monitorFrame: CGRect
    ) -> MouseInputState.LiveEdgeScroll.Edge? {
        guard let width = controller?.niriEngine?.moveConfiguration
            .liveEdgeZoneWidth(forDisplayWidth: monitorFrame.width)
        else { return nil }
        if location.x < monitorFrame.minX + width { return .leading }
        if location.x >= monitorFrame.maxX - width { return .trailing }
        return nil
    }
}
