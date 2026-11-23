// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    func requestFullRescan(
        reason: RefreshReason,
        scope: RescanScope = .all,
        reconcilesWorkspaceMonitorState: Bool? = nil
    ) {
        assert(reason.requestRoute == .fullRescan, "Invalid full-rescan reason: \(reason)")
        scheduleFullRescan(
            reason: reason,
            scope: scope.isEmpty ? .all : scope,
            reconcilesWorkspaceMonitorState: reconcilesWorkspaceMonitorState
        )
    }

    func requestRelayout(
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
        suppressWindowActivation: Bool = false
    ) {
        assert(reason.requestRoute == .relayout, "Invalid relayout reason: \(reason)")
        scheduleRefreshSession(
            reason.relayoutSchedulingPolicy,
            reason: reason,
            affectedWorkspaceIds: affectedWorkspaceIds,
            suppressWindowActivation: suppressWindowActivation
        )
    }

    func requestImmediateRelayout(
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
        postLayout: PostLayoutAction? = nil,
        postLayoutInvalidated: PostLayoutAction? = nil,
        postLayoutDomains: InvalidationDomain = [.workspace, .layout, .focus, .fullscreen],
        postLayoutGateWorkspaceIds: Set<WorkspaceDescriptor.ID>? = nil
    ) {
        assert(reason.requestRoute == .immediateRelayout, "Invalid immediate-relayout reason: \(reason)")
        let postLayoutWorkspaceIds = postLayoutGateWorkspaceIds
            ?? self.postLayoutWorkspaceIds(for: affectedWorkspaceIds)
        let postLayoutAction = makePostLayoutAction(
            postLayout,
            workspaceIds: postLayoutWorkspaceIds,
            domains: postLayoutDomains,
            invalidatedAction: postLayoutInvalidated
        )
        enqueueRefresh(
            .init(
                kind: .immediateRelayout,
                reason: reason,
                affectedWorkspaceIds: affectedWorkspaceIds,
                postLayout: postLayoutAction
            )
        )
    }

    func renderInteractiveResize(for workspaceId: WorkspaceDescriptor.ID, isInteractiveMove: Bool = false) {
        guard let controller,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else { return }
        _ = niriHandler.applyFramesOnDemand(
            wsId: workspaceId,
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            engine: engine,
            monitor: monitor,
            animationTime: nil,
            isInteractiveMove: isInteractiveMove
        )
    }

    func renderDwindleInteractiveResize(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else { return }
        _ = dwindleHandler.applyFramesOnDemand(workspaceId: workspaceId, monitor: monitor)
    }

    func requestLayoutCommandRelayout(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        postLayout: PostLayoutAction? = nil,
        postLayoutDomains: InvalidationDomain = [.workspace, .layout, .focus, .fullscreen]
    ) {
        assert(!affectedWorkspaceIds.isEmpty, "Layout command relayout must name affected workspaces")
        controller?.workspaceManager.invalidateLayout(for: affectedWorkspaceIds)
        requestImmediateRelayout(
            reason: .layoutCommand,
            affectedWorkspaceIds: affectedWorkspaceIds,
            postLayout: postLayout,
            postLayoutDomains: postLayoutDomains
        )
    }

    func requestVisibilityRefresh(
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
        postLayout: PostLayoutAction? = nil,
        postLayoutInvalidated: PostLayoutAction? = nil
    ) {
        assert(reason.requestRoute == .visibilityRefresh, "Invalid visibility-refresh reason: \(reason)")
        enqueueRefresh(
            .init(
                kind: .visibilityRefresh,
                reason: reason,
                affectedWorkspaceIds: affectedWorkspaceIds,
                postLayout: makePostLayoutAction(
                    postLayout,
                    workspaceIds: affectedWorkspaceIds.isEmpty
                        ? currentActiveWorkspaceIds()
                        : affectedWorkspaceIds,
                    invalidatedAction: postLayoutInvalidated
                )
            )
        )
    }

    func requestWindowRemoval(_ payload: WindowRemovalPayload, postLayout: PostLayoutAction? = nil) {
        assert(RefreshReason.windowDestroyed.requestRoute == .windowRemoval, "Invalid window-removal reason")
        enqueueRefresh(
            .init(
                kind: .windowRemoval,
                reason: .windowDestroyed,
                postLayout: makePostLayoutAction(postLayout, workspaceIds: [payload.workspaceId]),
                windowRemovalPayload: payload
            )
        )
    }

    func commitWorkspaceTransition(
        affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [],
        reason: RefreshReason = .workspaceTransition,
        postLayoutGateWorkspaceIds: Set<WorkspaceDescriptor.ID>? = nil,
        postLayout: PostLayoutAction? = nil,
        postLayoutInvalidated: PostLayoutAction? = nil
    ) {
        requestImmediateRelayout(
            reason: reason,
            affectedWorkspaceIds: affectedWorkspaces,
            postLayout: postLayout,
            postLayoutInvalidated: postLayoutInvalidated,
            postLayoutGateWorkspaceIds: postLayoutGateWorkspaceIds
        )
    }

    func makePostLayoutAction(
        _ postLayout: PostLayoutAction?,
        workspaceIds: Set<WorkspaceDescriptor.ID>,
        domains: InvalidationDomain = [.workspace, .layout, .focus, .fullscreen],
        invalidatedAction: PostLayoutAction? = nil
    ) -> RefreshPostLayoutAction? {
        guard let postLayout else { return nil }
        guard let controller, !workspaceIds.isEmpty else { return nil }
        let plannedSeq = controller.workspaceManager.worldSeq
        var seqs: [WorkspaceDescriptor.ID: UInt64] = [:]
        seqs.reserveCapacity(workspaceIds.count)
        for workspaceId in workspaceIds {
            seqs[workspaceId] = plannedSeq
        }
        return RefreshPostLayoutAction(
            workspaceSeqs: seqs,
            domains: domains,
            action: postLayout,
            invalidatedAction: invalidatedAction
        )
    }

    func acceptedPostLayoutAction(
        _ postLayout: PostLayoutAction?,
        workspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> RefreshPostLayoutAction? {
        guard let action = makePostLayoutAction(postLayout, workspaceIds: workspaceIds),
              let controller,
              action.isCurrent(using: controller.workspaceManager)
        else {
            return nil
        }
        return action
    }

    private func postLayoutWorkspaceIds(
        for affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> Set<WorkspaceDescriptor.ID> {
        affectedWorkspaceIds.isEmpty ? currentActiveWorkspaceIds() : affectedWorkspaceIds
    }

    private func scheduleFullRescan(
        reason: RefreshReason,
        scope: RescanScope,
        reconcilesWorkspaceMonitorState: Bool?
    ) {
        enqueueRefresh(
            .init(
                kind: .fullRescan,
                reason: reason,
                rescanScope: scope,
                reconcilesWorkspaceMonitorState: reconcilesWorkspaceMonitorState
            )
        )
    }

    private func scheduleRefreshSession(
        _ policy: RelayoutSchedulingPolicy,
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
        suppressWindowActivation: Bool = false
    ) {
        if policy.shouldDropWhileBusy {
            if layoutState.isIncrementalRefreshInProgress || layoutState.isImmediateLayoutInProgress {
                return
            }
            if !niriHandler.scrollAnimationByDisplay.isEmpty
                || !dwindleHandler.dwindleAnimationByDisplay.isEmpty
            {
                return
            }
        }
        let refresh = ScheduledRefresh(
            kind: .relayout,
            reason: reason,
            affectedWorkspaceIds: affectedWorkspaceIds,
            suppressesWindowActivation: suppressWindowActivation
        )
        let debounce = policy.debounceInterval
        if debounce > 0 {
            enqueueDebouncedRelayout(refresh, debounce: debounce)
        } else {
            enqueueRefresh(refresh)
        }
    }

    private func enqueueDebouncedRelayout(_ refresh: ScheduledRefresh, debounce intervalNanos: UInt64) {
        if layoutState.activeRefresh != nil {
            enqueueRefresh(refresh)
            return
        }
        performanceCounters?.refreshesEnqueued &+= 1
        mergePendingRefresh(refresh)
        guard layoutState.pendingDebounceTask == nil else { return }
        layoutState.pendingDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: intervalNanos)
            guard let self else { return }
            self.layoutState.pendingDebounceTask = nil
            self.startNextRefreshIfNeeded()
        }
    }

    func selectTabInNiri(
        info: TabRailInfo,
        visualIndex: Int,
        expectedToken: WindowToken?
    ) {
        niriHandler.selectTabInNiri(
            info: info,
            visualIndex: visualIndex,
            expectedToken: expectedToken
        )
    }
}
