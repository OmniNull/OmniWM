// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WorkspaceManager {
    func isWindowSuppressedByMacOS(_ token: WindowToken) -> Bool {
        isAppHidden(token) || entry(for: token)?.observedState.isNativeSuppressed == true
    }

    func isWindowSuppressedByMacOS(_ entry: borrowing WindowState) -> Bool {
        if isAppHidden(entry.token) { return true }
        return entry.observedState.isNativeSuppressed
    }

    @discardableResult
    func setWindowMinimized(
        _ minimized: Bool,
        token: WindowToken,
        source: WMEventSource = .ax
    ) -> Bool {
        guard let (workspaceId, isMinimized) = withEntry(token, { ($0.workspaceId, $0.observedState.isMinimized) }),
              isMinimized != minimized
        else { return false }
        if let parent = withEntry(token, { $0.target.hostedMetadata?.role.parent }) ?? nil {
            guard hostedFamilyRoot(for: token) == parent,
                  withEntry(parent, { $0.observedState.isMinimized }) == minimized else { return false }
        }
        let txn = recordReconcileEvent(.windowMinimizedChanged(
            token: token,
            workspaceId: workspaceId,
            minimized: minimized,
            source: source
        ))
        if txn.plan.focusSession != nil {
            notifySessionStateChanged()
        }
        drainPendingRuntimeMonitorOverrideClears()
        return true
    }

    @discardableResult
    func setWindowNativeWithdrawn(
        _ withdrawn: Bool,
        token: WindowToken,
        source: WMEventSource = .ax
    ) -> Bool {
        guard let (workspaceId, isNativeWithdrawn) = withEntry(token, {
                  ($0.workspaceId, $0.observedState.isNativeWithdrawn)
              }),
              isNativeWithdrawn != withdrawn
        else { return false }
        let txn = recordReconcileEvent(.windowNativeWithdrawalChanged(
            token: token,
            workspaceId: workspaceId,
            withdrawn: withdrawn,
            source: source
        ))
        if txn.plan.focusSession != nil {
            notifySessionStateChanged()
        }
        drainPendingRuntimeMonitorOverrideClears()
        return true
    }
}
