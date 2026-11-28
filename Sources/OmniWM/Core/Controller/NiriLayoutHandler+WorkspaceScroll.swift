// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutHandler {
    @discardableResult
    func scrollWorkspace(
        _ workspaceId: WorkspaceDescriptor.ID, to offset: CGFloat, animate: Bool
    ) throws(ConfigScriptDispatchRefusal) -> Bool {
        guard offset.isFinite else { throw .init(reason: "the scroll offset must be a finite number") }
        guard let controller, controller.workspaceManager.descriptor(for: workspaceId) != nil else {
            throw .init(reason: "no workspace has that ID")
        }
        let manager = controller.workspaceManager
        guard manager.activeLayoutKind(for: workspaceId) == .niri, let engine = controller.niriEngine else {
            throw .init(reason: "scrolling needs a Niri workspace")
        }
        guard let monitor = manager.monitor(for: workspaceId),
              manager.activeWorkspace(on: monitor.id)?.id == workspaceId
        else { throw .init(reason: "the workspace isn't shown on a display") }
        let state = manager.niriViewportState(for: workspaceId)
        let request = WorkspaceScrollRequest(workspaceId: workspaceId, monitor: monitor, state: state, offset: offset)
        try requireIdleViewport(request, controller: controller, engine: engine)
        guard let target = try preflightScroll(request, controller: controller, engine: engine),
              target != state.viewOffset
        else { return false }

        let motion = animate ? controller.motionPolicy.snapshot() : .disabled
        manager.withNiriViewportState(for: workspaceId) { viewport in
            viewport.preservesGestureOffset = true
            viewport.animateToOffset(target, motion: motion, scale: engine.displayScale(in: workspaceId))
        }
        controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [workspaceId])
        return true
    }

    private struct WorkspaceScrollRequest {
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let state: ViewportState
        let offset: CGFloat
    }

    private func requireIdleViewport(
        _ request: WorkspaceScrollRequest, controller: WMController, engine: NiriLayoutEngine
    ) throws(ConfigScriptDispatchRefusal) {
        let workspaceId = request.workspaceId
        let mouse = controller.mouseEventHandler
        let refresh = controller.layoutRefreshController
        let driver = controller.workspaceManager.animationDriver
        guard !mouse.isInteractiveGestureActive, !mouse.isTrackpadSwipeSessionActive,
              mouse.liveDragSession?.carriedWindow == nil, mouse.state.nativeTitleBarDrag == nil,
              refresh.workspaceSwipe.flights[request.monitor.id] == nil, !driver.hasGesture(in: workspaceId),
              engine.interactiveResize?.workspaceId != workspaceId, engine.interactiveMove?.workspaceId != workspaceId,
              !engine.isLiveStackDropPending(in: workspaceId)
        else { throw .init(reason: "a gesture, drag, swipe or resize is active") }
        guard !request.state.hasPendingOffsetAnimation, !driver.hasMotion(in: workspaceId),
              !hasScrollAnimation(for: workspaceId), !refresh.hasPendingScrollRelayout(in: workspaceId)
        else { throw .init(reason: "the Niri viewport is still settling") }
    }

    private func preflightScroll(
        _ request: WorkspaceScrollRequest, controller: WMController, engine: NiriLayoutEngine
    ) throws(ConfigScriptDispatchRefusal) -> CGFloat? {
        let workspaceId = request.workspaceId
        let exclusions = engine.projectionExclusions(in: workspaceId)
        let inventory = scrollInventory(in: workspaceId, controller: controller, engine: engine)
        if inventory.presented == 1 { return nil }

        let unavailable = ConfigScriptDispatchRefusal(reason: "settled Niri column geometry isn't available")
        guard inventory.matches, inventory.presented > 1,
              let root = engine.root(for: workspaceId),
              let monitor = engine.monitorForWorkspace(workspaceId), monitor.id == request.monitor.id,
              monitor.orientation == controller.settings.monitors.effectiveOrientation(for: request.monitor),
              monitor.frame == request.monitor.frame
        else { throw unavailable }
        let currentGeometry = controller.niriInteractionGeometry(for: request.monitor, scale: monitor.scale)
        let context = NiriInteractionContext(
            workspaceId: workspaceId, motion: .disabled, workingFrame: currentGeometry.workingFrame,
            gaps: currentGeometry.innerGap, orientation: monitor.orientation
        )
        let projection = root.cachedProjectedColumns ?? root.children.enumerated().compactMap { index, node in
            guard let column = node as? NiriContainer else { return nil }
            return NiriProjectedColumn(
                column: column, windows: column.children.compactMap { $0 as? NiriWindow }, durableIndex: index
            )
        }
        guard let strip = engine.resolvedScrollStrip(
            context: context, state: request.state, projection: projection, exclusions: exclusions
        ) else { throw unavailable }

        let settings = engine.effectiveSettings(in: workspaceId)
        let geometry = NiriViewportGeometry(
            gap: context.gaps, viewportSpan: context.primarySpan, orientation: context.orientation,
            workingArea: context.workingFrame, viewFrame: monitor.frame, scale: monitor.scale,
            edgeOverscroll: settings.edgeOverscroll
        )
        let reconcile = NiriScrollReconcile(
            keepsClickedSelectionOffscreen: request.state.clickFocusedNodeId != nil
                && request.state.clickFocusedNodeId == request.state.selectedNodeId
                && controller.settings.focus.clickFocusWithoutScrolling,
            settlesUnprojectedStrip: exclusions.isEmpty
        )
        guard let target = strip.scrollTarget(
            request.offset, geometry: geometry, settings: settings, edges: engine.viewportEdgeRules(in: workspaceId),
            reconcile: reconcile
        ) else { throw .init(reason: "the Niri layout policy would move the scroll offset") }
        return target
    }

    private func scrollInventory(
        in workspaceId: WorkspaceDescriptor.ID, controller: WMController, engine: NiriLayoutEngine
    ) -> (presented: Int, matches: Bool) {
        let manager = controller.workspaceManager
        let indexed = engine.states[workspaceId]?.nodesByToken ?? [:]
        let excluded = engine.projectionExclusions(in: workspaceId)
        var presented = 0
        var seen = 0
        var matches = true
        manager.windowQueries.forEachWindowForLayoutSnapshot(in: workspaceId, mode: .tiling) { entry in
            let suppressed = manager.isWindowSuppressedByMacOS(entry)
            seen += 1
            if !suppressed { presented += 1 }
            if indexed[entry.token] == nil || excluded.contains(entry.token) != suppressed { matches = false }
        }
        return (presented, matches && seen == indexed.count && (laidOutExclusions[workspaceId] ?? []) == excluded)
    }
}

extension LayoutRefreshController {
    fileprivate func hasPendingScrollRelayout(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        if let active = layoutState.activeRefresh, resolvedScheduledWorkspaceIds(active).contains(workspaceId) {
            return true
        }
        if let pending = layoutState.pendingRefresh, resolvedScheduledWorkspaceIds(pending).contains(workspaceId) {
            return true
        }
        return false
    }
}
