// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension WorldStore {
    func applyNiriGather(
        _ plan: NiriGatherPlan,
        assignments: StateReducer.GatherAssignmentPlan,
        monitors: [Monitor]
    ) {
        assertInCommit("applyNiriGather")
        guard let engine = niriEngine else {
            preconditionFailure("applyNiriGather requires the Niri engine that produced the plan")
        }
        engine.applyGather(plan)

        for patch in plan.workspaces {
            var state = viewports[patch.workspaceId] ?? ViewportState()
            state.selectedNodeId = patch.selectedNodeId
            state.activeColumnIndex = patch.activeColumnIndex
            if let refreshRate = engine.monitorForWorkspace(patch.workspaceId)?.refreshRate {
                state.displayRefreshRate = refreshRate
            }
            state.clearOffsetTransition()
            if viewports[patch.workspaceId] != state {
                applyViewportPlan(.set(workspaceId: patch.workspaceId, state: state))
            }
        }

        for patch in assignments.patches {
            updateWorkspace(for: patch.token, workspace: plan.destinationWorkspaceId, monitors: monitors)
            setObservedState(patch.observedState, for: patch.token)
            setDesiredState(patch.desiredState, for: patch.token)
        }
        if let focusSession = assignments.focusSession {
            applyFocusSession(focusSession)
        }
        refreshProjectionExclusions(in: Set(plan.affectedWorkspaceIds))

        for token in plan.request.tokens {
            guard let entry = windows.entry(for: token) else { continue }
            let restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
            if entry.restoreIntent != restoreIntent {
                setRestoreIntent(restoreIntent, for: token)
            }
        }
        captureLiveNiriPlacements(
            containing: plan.request.tokens,
            in: plan.destinationWorkspaceId,
            monitors: monitors
        )
    }
}
