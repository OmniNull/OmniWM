// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func carryLiveColumnDrag(from sourceWorkspaceId: WorkspaceDescriptor.ID, at location: CGPoint) -> Bool {
        guard let controller,
              let targetWorkspaceId = liveStripWorkspace(at: location, requiringNiriEligibility: false),
              targetWorkspaceId != sourceWorkspaceId
        else { return liveCrossDisplayMove != nil }
        if liveCrossDisplayMove != nil || !controller.isNiriStrip(targetWorkspaceId) {
            return carryLiveDragAcrossDisplays(at: location, crossingTo: targetWorkspaceId)
        }
        guard !hasPendingNativeFullscreenTransition(at: location),
              !isPointerDisplayShowingFullscreenSpace(at: location),
              let engine = controller.niriEngine,
              let move = engine.liveColumnMove,
              let source = liveColumnContext(for: sourceWorkspaceId),
              let target = liveColumnContext(for: targetWorkspaceId),
              engine.liveColumnMoveCanCarry(from: source, to: target)
        else { return false }
        let observed = move.floatingFrame ?? controller.workspaceManager.entry(for: move.windowToken)
            .flatMap { $0.axRef.flatMap(nativeWindowFrameProvider) }
        let windowPrimarySpan: CGFloat? = if let observed { target.primarySpan(of: observed) } else { nil }
        endLiveEdgeScroll()
        cancelLiveHoverCheck()
        var carried: [WindowToken] = []
        controller.workspaceManager.withBatchedCrossWorkspaceDrop(
            into: targetWorkspaceId,
            niriWorkspaceIds: [sourceWorkspaceId, targetWorkspaceId]
        ) { viewports in
            carried = engine.liveColumnMoveCarry(
                cursor: location,
                windowPrimarySpan: windowPrimarySpan,
                from: source,
                to: target,
                viewports: &viewports
            )
            return carried.map { .init(token: $0, workspaceId: targetWorkspaceId) }
        }
        guard !carried.isEmpty else { return false }
        if source.orientation != target.orientation, liveDragSession?.carriedWindow == nil {
            liveDragSession?.referenceOffset = if let observed {
                target.primaryStart(of: observed) + target.primarySpan(of: observed) / 2
                    - target.primaryCoordinate(of: location)
            } else { nil }
        }
        refreshLiveColumnLayout(in: sourceWorkspaceId, engine: engine)
        refreshLiveColumnLayout(in: targetWorkspaceId, engine: engine)
        if let monitor = controller.workspaceManager.monitor(for: targetWorkspaceId) {
            holdLiveEdgeZone(startingAt: location, monitorFrame: monitor.frame, orientation: target.orientation)
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
        let viewport = controller.workspaceManager.niriViewportState(for: workspaceId)
        let strip = liveColumnContext(for: workspaceId).map {
            engine.liveColumnStrip(context: $0, state: viewport)
        } ?? []
        traceLiveStrip(label, in: workspaceId, at: location, strip: strip, viewport: viewport)
    }

    func traceLiveStrip(
        _ label: String,
        in workspaceId: WorkspaceDescriptor.ID,
        at location: CGPoint?,
        strip: [LiveColumnMove.StripColumn],
        viewport: ViewportState
    ) {
        guard MouseTrace.shared.isActive,
              let controller,
              let engine = controller.niriEngine
        else { return }
        let move = engine.liveColumnMove
        let live = controller.workspaceManager.animationDriver.liveViewOffset(
            in: workspaceId,
            semanticOffset: viewport.viewOffset
        )
        let trace = LiveStripTrace(
            label: label,
            workspaceId: workspaceId,
            activeColumnIndex: viewport.activeColumnIndex,
            viewOffset: String(format: "%.0f", viewport.viewOffset),
            liveOffset: live.map { String(format: "%.0f", $0) },
            lock: move?.lockedTarget.map { lock in
                .init(
                    windowIds: engine.liveColumn(withId: lock.columnId, in: workspaceId)?.windowNodes
                        .map(\.token.windowId),
                    side: lock.side
                )
            },
            columns: strip.map { placed in
                .init(
                    windowIds: placed.column.windowNodes.map(\.token.windowId),
                    isHomeSpot: placed.column.isLiveHomeSpot,
                    isDropSpace: placed.column.isLiveDropSpace,
                    minX: Int(placed.minX),
                    maxX: Int(placed.maxX)
                )
            },
            phase: move?.phase
        )
        guard !label.hasPrefix("update") || trace != liveDragSession?.tracedView else { return }
        liveDragSession?.tracedView = trace
        MouseTrace.record("live-drag \(label) at=\(TraceFormat.point(location)) \(trace.view)")
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

    func hasOtherLiveDisplay(than context: NiriInteractionContext) -> Bool {
        guard let controller else { return false }
        let manager = controller.workspaceManager
        return manager.monitors.contains { monitor in
            guard let other = manager.activeWorkspaceOrFirst(on: monitor.id)?.id, other != context.workspaceId else {
                return false
            }
            return true
        }
    }

    private func liveStripWorkspace(
        at location: CGPoint,
        requiringNiriEligibility: Bool = true
    ) -> WorkspaceDescriptor.ID? {
        guard let controller,
              let monitor = controller.workspaceManager.monitors.first(where: { $0.frame.contains(location) }),
              let workspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              !requiringNiriEligibility || controller.isNiriStrip(workspaceId),
              !requiringNiriEligibility || !hasPendingNativeFullscreenTransition(at: location),
              !requiringNiriEligibility || !isPointerDisplayShowingFullscreenSpace(at: location)
        else { return nil }
        return workspaceId
    }
}
