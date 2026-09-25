// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func pendingManagedFocusMatches(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        requestId: UInt64
    ) -> Bool {
        let request = focusSessionSnapshot.pendingManagedFocus
        return request.token == token
            && request.workspaceId == workspaceId
            && request.requestId == requestId
    }

    func eligibleFocusCandidate(
        _ token: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> WindowToken? {
        guard let token,
              let entry = entry(for: token),
              isFocusResolutionEligible(entry, in: workspaceId, mode: mode)
        else {
            return nil
        }
        return token
    }

    func isFocusResolutionEligible(
        _ entry: WindowState,
        in workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> Bool {
        guard entry.workspaceId == workspaceId,
              entry.mode == mode,
              !isWindowSuppressedByMacOS(entry)
        else {
            return false
        }

        guard let hiddenState = entry.hiddenState else {
            return true
        }

        return hiddenState.workspaceInactive
    }

    @discardableResult
    func updateScratchpadMembership(
        _ token: WindowToken,
        to index: ScratchpadIndex?,
        notify: Bool
    ) -> Bool {
        guard scratchpadIndex(for: token) != index else { return false }
        let workspaceId = windowQueries.entry(for: token)?.workspaceId
        if index != nil, workspaceId == nil {
            return false
        }
        recordReconcileEvent(
            .scratchpadMembershipChanged(token: token, index: index, source: .workspaceManager)
        )
        if let workspaceId {
            noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout, .focus])
        }
        if notify {
            notifySessionStateChanged()
        }
        drainPendingRuntimeMonitorOverrideClears()
        return true
    }
}
