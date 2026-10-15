// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension WorkspaceManager {
    func planNiriGather(_ request: NiriGatherRequest) -> NiriGatherPlanning {
        guard let engine = niriEngine else {
            return .refused(.windows(Dictionary(uniqueKeysWithValues: request.tokens.map { ($0, .layoutConflict) })))
        }
        let workspaceIds = Set(request.sourceWorkspaceIds.values).union([request.destinationWorkspaceId])
        let selections = workspaceIds.reduce(into: [WorkspaceDescriptor.ID: NodeId]()) { selections, workspaceId in
            selections[workspaceId] = recordedViewportStates[workspaceId]?.selectedNodeId
        }
        return engine.planGather(request, selections: selections)
    }

    @discardableResult
    func commitNiriGather(_ plan: NiriGatherPlan) -> Bool {
        let request = plan.request
        let destinationId = request.destinationWorkspaceId
        let entries = request.tokens.compactMap { windowQueries.entry(for: $0) }
        guard descriptor(for: destinationId) != nil,
              entries.count == request.tokens.count,
              entries.allSatisfy({ $0.mode == .tiling && request.sourceWorkspaceIds[$0.token] == $0.workspaceId }),
              planNiriGather(request) == .ready(plan)
        else {
            return false
        }

        let assignments = StateReducer.gatherAssignments(
            entries,
            to: destinationId,
            monitorId: monitorId(for: destinationId),
            focusSession: focusSessionSnapshot
        )
        let affectedWorkspaceIds = plan.affectedWorkspaceIds
        let previousViewports = affectedWorkspaceIds.map { recordedViewportStates[$0] }
        commitWorldEvent(
            .userCommand(workspaceId: destinationId, label: "niri_gather", source: .command),
            monitors: monitors,
            preMutate: {
                self.applyNiriGather(plan, assignments: assignments)
            },
            resolvePlan: { plan, _, _ in plan }
        )

        for (workspaceId, previous) in zip(affectedWorkspaceIds, previousViewports) {
            animationDriver.reconcileViewportCommit(
                workspaceId: workspaceId,
                previous: previous,
                next: niriViewportState(for: workspaceId),
                transition: OffsetTransition()
            )
        }
        noteInvalidation(workspaceIds: Set(affectedWorkspaceIds), domains: [.workspace, .layout, .focus])
        schedulePersistedWindowRestoreCatalogSave()
        return true
    }
}
