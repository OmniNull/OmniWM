// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension StateReducer {
    struct GatherAssignmentPatch: Equatable {
        let token: WindowToken
        let sourceWorkspaceId: WorkspaceDescriptor.ID
        let observedState: ObservedWindowState
        let desiredState: DesiredWindowState
    }

    struct GatherAssignmentPlan: Equatable {
        var patches: [GatherAssignmentPatch] = []
        var focusSession: FocusSessionSnapshot?
    }

    static func gatherAssignments(
        _ entries: [WindowState],
        to workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        focusSession: FocusSessionSnapshot
    ) -> GatherAssignmentPlan {
        var plan = GatherAssignmentPlan()
        var runningFocus = focusSession
        for entry in entries where entry.workspaceId != workspaceId {
            plan.patches.append(
                GatherAssignmentPatch(
                    token: entry.token,
                    sourceWorkspaceId: entry.workspaceId,
                    observedState: baseObservedState(from: entry, workspaceId: workspaceId, monitorId: monitorId),
                    desiredState: baseDesiredState(
                        from: entry,
                        workspaceId: workspaceId,
                        monitorId: monitorId,
                        mode: entry.mode
                    )
                )
            )
            runningFocus = reassigningFocusState(
                from: runningFocus,
                token: entry.token,
                sourceWorkspaceId: entry.workspaceId,
                workspaceId: workspaceId
            ) ?? runningFocus
        }
        if runningFocus != focusSession {
            plan.focusSession = runningFocus
        }
        return plan
    }
}
