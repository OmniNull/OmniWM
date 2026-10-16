// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    @discardableResult
    func removeWindow(pid: pid_t, windowId: Int) -> WindowState? {
        guard let entry = windowQueries.entry(forPid: pid, windowId: windowId) else { return nil }
        let removedEntry = removeTrackedWindow(entry)
        schedulePersistedWindowRestoreCatalogSave()
        return removedEntry
    }

    @discardableResult
    func removeWindowsForApp(pid: pid_t) -> Set<WorkspaceDescriptor.ID> {
        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = []
        let entriesToRemove = entries(forPid: pid)

        for entry in entriesToRemove {
            affectedWorkspaces.insert(entry.workspaceId)
            _ = removeTrackedWindow(entry)
        }

        if !entriesToRemove.isEmpty {
            schedulePersistedWindowRestoreCatalogSave()
        }

        return affectedWorkspaces
    }

    @discardableResult
    private func removeTrackedWindow(_ entry: WindowState) -> WindowState {
        let previousFocus = focusSessionSnapshot
        let removesNativeFullscreenFocusOwner = activeNativeFullscreenFocusOwnerToken == entry.token
        recordReconcileEvent(
            .windowRemoved(
                token: entry.token,
                workspaceId: entry.workspaceId,
                source: .workspaceManager
            )
        )
        _ = removeNativeFullscreenRecord(containing: entry.token)
        quietArrivalTokens.remove(entry.token)
        if removesNativeFullscreenFocusOwner {
            _ = clearNativeFocusOwner()
        }
        let focusChanged = auxiliaryFocusStateChanged(from: previousFocus)
        let scratchpadChanged = updateScratchpadMembership(entry.token, to: nil, notify: false)
        if focusChanged || scratchpadChanged {
            notifySessionStateChanged()
        }
        drainPendingRuntimeMonitorOverrideClears()
        onWindowRemoved?(entry)
        return entry
    }

    func setWorkspace(for token: WindowToken, to workspace: WorkspaceDescriptor.ID) {
        let previousWorkspace = windowQueries.workspace(for: token)
        guard previousWorkspace != workspace else { return }
        quietArrivalTokens.remove(token)
        if let originalToken = nativeFullscreenOriginalToken(forCurrentToken: token),
           var record = nativeFullscreenRecordsByOriginalToken[originalToken],
           record.currentToken == token,
           record.workspaceId != workspace
        {
            record.workspaceId = workspace
            upsertNativeFullscreenRecord(record)
        }
        recordReconcileEvent(
            .workspaceAssigned(
                token: token,
                from: previousWorkspace,
                to: workspace,
                monitorId: monitorId(for: workspace),
                source: .workspaceManager
            )
        )
        if scratchpadIndex(for: token) != nil,
           previousWorkspace.map(pendingRuntimeMonitorOverrideClearWorkspaceIds.contains) == true
        {
            drainPendingRuntimeMonitorOverrideClears()
        }
    }

    func workspace(for token: WindowToken) -> WorkspaceDescriptor.ID? {
        windowQueries.workspace(for: token)
    }

    func isHiddenInCorner(_ token: WindowToken) -> Bool {
        windowQueries.isHiddenInCorner(token)
    }

    func setHiddenState(_ state: HiddenState?, for token: WindowToken) {
        guard windowQueries.hiddenState(for: token) != state else { return }
        guard let workspaceId = workspace(for: token) else { return }
        recordReconcileEvent(
            .hiddenStateChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId(for: workspaceId),
                hiddenState: state,
                source: .workspaceManager
            )
        )
        drainPendingRuntimeMonitorOverrideClears()
    }

    func hiddenState(for token: WindowToken) -> HiddenState? {
        windowQueries.hiddenState(for: token)
    }

    func layoutReason(for token: WindowToken) -> LayoutReason {
        windowQueries.layoutReason(for: token)
    }

    func isNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
        windowQueries.isNativeFullscreenSuspended(token)
    }

    func setLayoutReason(_ reason: LayoutReason, for token: WindowToken) {
        guard windowQueries.layoutReason(for: token) != reason else { return }
        guard let workspaceId = workspace(for: token) else { return }
        recordReconcileEvent(
            .nativeFullscreenTransition(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId(for: workspaceId),
                change: .suspended(reason),
                source: .workspaceManager
            )
        )
    }

    @discardableResult
    func restoreFromNativeState(
        for token: WindowToken,
        drainPendingRuntimeMonitorOverrides: Bool = true
    ) -> Bool {
        guard let entry = windowQueries.entry(for: token),
              entry.layoutReason != .standard,
              let workspaceId = workspace(for: token)
        else {
            return false
        }
        recordReconcileEvent(
            .nativeFullscreenTransition(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId(for: workspaceId),
                change: .restored,
                source: .workspaceManager
            )
        )
        if drainPendingRuntimeMonitorOverrides, nativeFullscreenRecord(for: token) == nil {
            drainPendingRuntimeMonitorOverrideClears()
        }
        return true
    }

    func showsNativeFullscreenPlaceholder(for token: WindowToken) -> Bool {
        guard layoutReason(for: token) == .nativeFullscreen else { return false }
        guard let record = nativeFullscreenRecord(for: token) else { return false }
        guard record.currentToken == token else { return false }
        return record.transition == .suspended
    }
}
