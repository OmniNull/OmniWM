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
            controller?.niriEngine?.liveColumnMovePointerInEdgeZone(false)
            controller?.niriEngine?.liveColumnMoveEdgeScrolls(toward: nil)
            clearLiveEdgeZone()
            return
        }
        controller?.niriEngine?.liveColumnMovePointerInEdgeZone(true)
        if let hold = state.liveEdgeZoneHold, hold.edge == edge, !hold.isPassed(by: location) { return }
        state.liveEdgeZoneHold = nil
        guard state.liveEdgeScroll?.edge != edge else { return }
        endLiveEdgeScroll()
        controller?.niriEngine?.liveColumnMoveEdgeScrolls(toward: nil)
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
              !edgeScroll.hopping,
              !edgeScroll.hopsDone,
              isLiveColumnDragActive,
              let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              move.phase == .dragging,
              liveDragClock() - edgeScroll.enteredAt >= engine.moveConfiguration.liveEdgeScrollDelay - 0.005,
              let context = liveColumnContext(for: move.workspaceId)
        else { return }

        let workspaceId = move.workspaceId
        if engine.moveConfiguration.liveEdgeHops, !move.stackMode, !move.inStack {
            edgeScroll.hopping = true
            state.liveEdgeScroll = edgeScroll
            runLiveEdgeHop()
            return
        }
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
        engine.liveColumnMoveEdgeScrolls(toward: edgeScroll.edge == .trailing ? .after : .before)
        MouseTrace.record("live-drag edge-scroll start edge=\(edgeScroll.edge) ws=\(workspaceId) limit=\(Int(limit))")
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { viewportState in
            _ = engine.liveColumnMoveCloseLandingForEdgeScroll(context: context, state: &viewportState)
        }
        controller.layoutRefreshController.startScrollAnimation(for: workspaceId, forGesture: true)
    }

    func runLiveEdgeHop() {
        guard var edgeScroll = state.liveEdgeScroll,
              edgeScroll.hopping,
              isLiveColumnDragActive,
              let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              let context = liveColumnContext(for: move.workspaceId)
        else { return }
        let workspaceId = move.workspaceId
        let towardTrailingEdge = edgeScroll.edge == .trailing
        engine.liveColumnMoveEdgeScrolls(toward: towardTrailingEdge ? .after : .before)
        let hopped = controller.workspaceManager.withNiriViewportState(
            for: workspaceId,
            committingIf: { $0 != nil },
            { engine.liveColumnMoveHop(towardTrailingEdge: towardTrailingEdge, context: context, state: &$0) }
        )
        guard let hopped else {
            edgeScroll.hopping = false
            edgeScroll.hopsDone = true
            state.liveEdgeScroll = edgeScroll
            return
        }
        MouseTrace.record(
            "live-drag edge-hop toward=\(edgeScroll.edge) target=\(hopped.traceWindowIds)"
                + " hidden=[\(hiddenColumnIds(in: workspaceId, engine: engine))]"
        )
        refreshLiveColumnLayout(in: workspaceId, engine: engine)
        edgeScroll.hopSettledSince = nil
        state.liveEdgeScroll = edgeScroll
        scheduleLiveEdgeHopCheck()
    }

    private func hiddenColumnIds(in workspaceId: WorkspaceDescriptor.ID, engine: NiriLayoutEngine) -> String {
        engine.columns(in: workspaceId)
            .filter { column in
                !column.isLiveDropSpace && !column.isLiveHomeSpot
                    && engine.projectedWindows(in: column, workspaceId: workspaceId).isEmpty
            }
            .map(\.traceWindowIds)
            .joined(separator: ",")
    }

    private func scheduleLiveEdgeHopCheck() {
        state.liveEdgeScroll?.delayTimer?.invalidate()
        state.liveEdgeScroll?.delayTimer = scheduleLiveDragTimer(after: 0.05) { [weak self] in
            self?.checkLiveEdgeHop()
        }
    }

    private func checkLiveEdgeHop() {
        guard var edgeScroll = state.liveEdgeScroll,
              edgeScroll.hopping,
              let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove
        else { return }
        if hasPendingLiveColumnAnimation(in: move.workspaceId, engine: engine) {
            edgeScroll.hopSettledSince = nil
            state.liveEdgeScroll = edgeScroll
            scheduleLiveEdgeHopCheck()
            return
        }
        if move.phase == .settling {
            engine.liveColumnMoveSettled()
        }
        let now = liveDragClock()
        let since = edgeScroll.hopSettledSince ?? now
        edgeScroll.hopSettledSince = since
        state.liveEdgeScroll = edgeScroll
        guard now - since >= engine.moveConfiguration.liveEdgeHopPause - 0.005 else {
            scheduleLiveEdgeHopCheck()
            return
        }
        runLiveEdgeHop()
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
            || !move.stackMode
            && liveEdgeScrollReachesColumn(
                at: liveDragReference(location),
                time: time,
                engine: engine,
                workspaceId: workspaceId
            )
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

    func publishLiveDragHold(on monitor: Monitor, workspaceId: WorkspaceDescriptor.ID) {
        guard let controller,
              let engine = controller.niriEngine,
              let context = liveColumnContext(for: workspaceId)
        else {
            controller?.pointerEdgeBarrier.publishLiveDragHold(nil)
            return
        }
        let viewportState = controller.workspaceManager.niriViewportState(for: workspaceId)
        let scrollingEdge = isLiveEdgeScrolling ? state.liveEdgeScroll?.edge : nil
        var held: Set<Direction> = []
        if scrollingEdge == .trailing
            || engine.liveEdgeScrollLimit(towardTrailingEdge: true, context: context, state: viewportState) != nil
        {
            held.insert(.right)
        }
        if scrollingEdge == .leading
            || engine.liveEdgeScrollLimit(towardTrailingEdge: false, context: context, state: viewportState) != nil
        {
            held.insert(.left)
        }
        controller.pointerEdgeBarrier.publishLiveDragHold(.init(monitorId: monitor.id, heldDirections: held))
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
