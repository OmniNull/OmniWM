// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func carryLiveColumnDrag(from sourceWorkspaceId: WorkspaceDescriptor.ID, at location: CGPoint) -> Bool {
        guard let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              let targetWorkspaceId = liveStripWorkspace(at: location),
              targetWorkspaceId != sourceWorkspaceId,
              let source = liveColumnContext(for: sourceWorkspaceId),
              let target = liveColumnContext(for: targetWorkspaceId),
              engine.liveColumnMoveCanCarry(from: sourceWorkspaceId, to: target)
        else { return false }
        let entry = controller.workspaceManager.entry(for: move.windowToken)
        let windowWidth = entry.flatMap { $0.axRef.flatMap(nativeWindowFrameProvider)?.width }
        endLiveEdgeScroll()
        cancelLiveHoverCheck()
        var carried: [WindowToken] = []
        controller.workspaceManager.withBatchedCrossWorkspaceDrop(
            into: targetWorkspaceId,
            niriWorkspaceIds: [sourceWorkspaceId, targetWorkspaceId]
        ) { viewports in
            var sourceState = viewports[sourceWorkspaceId] ?? ViewportState()
            var targetState = viewports[targetWorkspaceId] ?? ViewportState()
            carried = engine.liveColumnMoveCarry(
                cursor: location,
                windowWidth: windowWidth,
                from: source,
                sourceState: &sourceState,
                to: target,
                targetState: &targetState
            )
            viewports[sourceWorkspaceId] = sourceState
            viewports[targetWorkspaceId] = targetState
            return carried.map { .init(token: $0, workspaceId: targetWorkspaceId) }
        }
        guard !carried.isEmpty else { return false }
        refreshLiveColumnLayout(in: sourceWorkspaceId, engine: engine)
        refreshLiveColumnLayout(in: targetWorkspaceId, engine: engine)
        if let monitor = controller.workspaceManager.monitor(for: targetWorkspaceId) {
            publishLiveDragHold(on: monitor, workspaceId: targetWorkspaceId)
        }
        traceLiveDrag("carried from=\(sourceWorkspaceId)", at: location)
        return true
    }

    func resumeHandedOverLiveColumnDrag(at location: CGPoint) {
        guard var drag = state.nativeTitleBarDrag,
              drag.liveDragHandedOver,
              !drag.liveDrag,
              liveStripWorkspace(at: location) != nil,
              let entry = controller?.workspaceManager.entry(for: drag.token)
        else { return }
        drag.liveDragHandedOver = false
        drag.liveDragDeclined = false
        guard beginLiveColumnDragIfEligible(&drag, entry: entry) else { return }
        state.nativeTitleBarDrag = drag
        traceLiveDrag("resumed after hand-over", at: location)
    }

    func traceLiveDrag(_ label: String, at location: CGPoint) {
        guard MouseTrace.shared.isActive, let move = controller?.niriEngine?.liveColumnMove else { return }
        traceLiveStrip(label, in: move.workspaceId, at: location)
    }

    func traceLiveStrip(_ label: String, in workspaceId: WorkspaceDescriptor.ID, at location: CGPoint?) {
        guard MouseTrace.shared.isActive,
              let controller,
              let engine = controller.niriEngine
        else { return }
        let move = engine.liveColumnMove
        let viewport = controller.workspaceManager.niriViewportState(for: workspaceId)
        let live = controller.workspaceManager.animationDriver.liveViewOffset(
            in: workspaceId,
            semanticOffset: viewport.viewOffset
        )
        let strip = liveColumnContext(for: workspaceId).map {
            engine.liveColumnStrip(context: $0, state: viewport)
        } ?? []
        let columns = strip.map { placed in
            let column = placed.column
            let ids = column.traceWindowIds
            let name = column.isLiveHomeSpot ? "*\(ids)" : column.isLiveDropSpace ? "_" : ids
            return "\(name)@\(Int(placed.minX))-\(Int(placed.maxX))"
        }
        let lock = move?.lockedTarget.map { lock in
            let ids = engine.liveColumn(withId: lock.columnId, in: workspaceId)?.traceWindowIds ?? "?"
            return "\(ids)/\(lock.side)"
        } ?? "none"
        let view = "ws=\(workspaceId) active=\(viewport.activeColumnIndex) "
            + String(format: "off=%.0f live=%@ ", viewport.viewOffset, live.map { String(format: "%.0f", $0) } ?? "-")
            + "lock=\(lock) cols=[\(columns.joined(separator: ","))] phase=\(move.map { "\($0.phase)" } ?? "-")"
        guard label != "update" || view != state.liveDragTracedView else { return }
        state.liveDragTracedView = view
        MouseTrace.record("live-drag \(label) at=\(TraceFormat.point(location)) \(view)")
    }

    func returnCarriedLiveColumnDragHome() {
        guard let controller,
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              let carry = move.carry
        else { return }
        let originalWorkspaceId = carry.originalWorkspaceId
        var workspaceIds = [move.workspaceId]
        for workspaceId in carry.visitedStrips.map(\.workspaceId) + [originalWorkspaceId]
            where !workspaceIds.contains(workspaceId)
        {
            workspaceIds.append(workspaceId)
        }
        let contexts = Dictionary(uniqueKeysWithValues: workspaceIds.compactMap { workspaceId in
            liveColumnContext(for: workspaceId).map { (workspaceId, $0) }
        })
        controller.workspaceManager.withBatchedCrossWorkspaceDrop(
            into: originalWorkspaceId,
            niriWorkspaceIds: workspaceIds
        ) { viewports in
            engine.liveColumnMoveReturnHome(contexts: contexts, viewports: &viewports)
                .map { .init(token: $0, workspaceId: originalWorkspaceId) }
        }
        for workspaceId in workspaceIds {
            refreshLiveColumnLayout(in: workspaceId, engine: engine)
        }
    }

    func hasOtherLiveStrip(than workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let manager = controller?.workspaceManager else { return false }
        return manager.monitors.contains { monitor in
            guard let other = manager.activeWorkspaceOrFirst(on: monitor.id)?.id, other != workspaceId else {
                return false
            }
            return isLiveStrip(other)
        }
    }

    private func liveStripWorkspace(at location: CGPoint) -> WorkspaceDescriptor.ID? {
        guard let manager = controller?.workspaceManager,
              let monitor = manager.monitors.first(where: { $0.frame.contains(location) }),
              let workspaceId = manager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              isLiveStrip(workspaceId),
              !hasPendingNativeFullscreenTransition(at: location),
              !isPointerDisplayShowingFullscreenSpace(at: location)
        else { return nil }
        return workspaceId
    }

    private func isLiveStrip(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        controller?.workspaceManager.activeLayoutKind(for: workspaceId) == .niri
            && liveColumnContext(for: workspaceId)?.orientation == .horizontal
    }
}
