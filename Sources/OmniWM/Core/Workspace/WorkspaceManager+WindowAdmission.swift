// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    @discardableResult
    func addWindow(
        _ ax: AXWindowRef,
        pid: pid_t,
        windowId: Int,
        to workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode = .tiling,
        ruleEffects: ManagedWindowRuleEffects = .none,
        admissionHints: ManagedWindowAdmissionHints = .none,
        lifetimeAuthority: ManagedWindowLifetimeAuthority = .axTopLevelInventory,
        allowsNativeFocusAdoption: Bool = true,
        isMinimized: Bool = false,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowToken {
        let token = WindowToken(pid: pid, windowId: windowId)
        if let existingEntry = windowQueries.entry(forWindowId: windowId), existingEntry.token != token {
            Log.reconcile.fault(
                "WorkspaceManager rejected duplicate windowId=\(windowId) existing=\(existingEntry.pid):\(existingEntry.windowId) proposed=\(pid):\(windowId)"
            )
            return existingEntry.token
        }
        if let existingEntry = windowQueries.entry(for: token), existingEntry.axRef == nil {
            return token
        }
        let adoptNativeFocus = allowsNativeFocusAdoption
            && !isMinimized
            && windowQueries.entry(for: token) == nil
            && nativeFullscreenRecord(for: token) == nil
            && focusSessionSnapshot.pendingManagedFocus == .empty
            && focusSessionSnapshot.nativeFocusOwner.externalToken == token
        if let originalToken = nativeFullscreenOriginalToken(forCurrentToken: token),
           var record = nativeFullscreenRecordsByOriginalToken[originalToken],
           record.currentToken == token,
           record.workspaceId != workspace
        {
            record.workspaceId = workspace
            upsertNativeFullscreenRecord(record)
        }
        let txn = recordReconcileEvent(
            .windowAdmitted(
                token: token,
                workspaceId: workspace,
                monitorId: monitorId(for: workspace),
                mode: mode,
                axRef: ax,
                ruleEffects: ruleEffects,
                admissionHints: admissionHints,
                lifetimeAuthority: lifetimeAuthority,
                adoptNativeFocus: adoptNativeFocus,
                managedReplacementMetadata: managedReplacementMetadata,
                source: .workspaceManager
            )
        )
        if isMinimized {
            setWindowMinimized(true, token: token, source: .workspaceManager)
        }
        if let handle = windowQueries.handle(for: token) {
            onWindowPresenceObserved?(handle)
        }
        if txn.plan.focusSession != nil {
            notifySessionStateChanged()
            drainPendingRuntimeMonitorOverrideClears()
        }
        return token
    }

    @discardableResult
    func addHostedWindow(
        token: WindowToken,
        metadata: HostedWindowMetadata,
        to workspace: WorkspaceDescriptor.ID,
        initialFrame: CGRect
    ) -> WindowToken? {
        guard token.pid == getpid(), token.windowId > 0,
              !metadata.appId.isEmpty,
              metadata.minimumSize.width.isFinite, metadata.minimumSize.width > 0,
              metadata.minimumSize.height.isFinite, metadata.minimumSize.height > 0,
              initialFrame.origin.x.isFinite, initialFrame.origin.y.isFinite,
              initialFrame.width.isFinite, initialFrame.width > 0,
              initialFrame.height.isFinite, initialFrame.height > 0,
              windowQueries.entry(forWindowId: token.windowId) == nil
        else { return nil }
        if let parent = metadata.role.parent {
            guard let entry = entry(for: parent), let owner = entry.target.hostedMetadata,
                  owner.role == .main, owner.instanceID == metadata.instanceID,
                  entry.workspaceId == workspace else { return nil }
        }
        recordReconcileEvent(
            .windowAdmitted(
                token: token,
                workspaceId: workspace,
                monitorId: monitorId(for: workspace),
                mode: metadata.role == .main && !metadata.admitsFloating ? .tiling : .floating,
                target: .hosted(metadata),
                ruleEffects: .none,
                admissionHints: .none,
                lifetimeAuthority: .directLifecycle,
                adoptNativeFocus: false,
                managedReplacementMetadata: nil,
                source: .workspaceManager,
                initialFrame: initialFrame
            )
        )
        if let handle = windowQueries.handle(for: token) {
            onWindowPresenceObserved?(handle)
        }
        return token
    }

    @discardableResult
    func promoteLifetimeAuthorityForObservedTopLevelWindows(_ tokens: Set<WindowToken>) -> Bool {
        var promotableTokens: Set<WindowToken> = []
        for token in tokens where windowQueries.withEntry(token, {
            $0.lifetimeAuthority == .directLifecycle && $0.axRef != nil
        }) == true {
            promotableTokens.insert(token)
        }
        guard !promotableTokens.isEmpty else { return false }
        recordReconcileEvent(
            .topLevelInventoryObserved(
                tokens: promotableTokens,
                source: .workspaceManager
            )
        )
        return true
    }

    @discardableResult
    func rekeyWindow(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        newAXRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowState? {
        guard let existingEntry = windowQueries.entry(for: oldToken),
              existingEntry.axRef != nil,
              oldToken == newToken || windowQueries.entry(for: newToken) == nil
        else {
            return nil
        }
        if oldToken != newToken,
           let collision = windowQueries.entry(forWindowId: newToken.windowId),
           collision.token != oldToken
        {
            return nil
        }

        if let originalToken = nativeFullscreenOriginalToken(forCurrentToken: oldToken),
           var record = nativeFullscreenRecordsByOriginalToken[originalToken]
        {
            record.currentToken = newToken
            record.workspaceId = existingEntry.workspaceId
            upsertNativeFullscreenRecord(record)
        }

        let previousFocus = focusSessionSnapshot
        recordReconcileEvent(
            .windowRekeyed(
                from: oldToken,
                to: newToken,
                workspaceId: existingEntry.workspaceId,
                monitorId: monitorId(for: existingEntry.workspaceId),
                reason: managedReplacementMetadata == nil ? .manualRekey : .managedReplacement,
                newAXRef: newAXRef,
                managedReplacementMetadata: managedReplacementMetadata,
                source: .workspaceManager
            )
        )

        let focusChanged = auxiliaryFocusStateChanged(from: previousFocus)
        if focusChanged || scratchpadIndex(for: newToken) != nil {
            notifySessionStateChanged()
        }

        return windowQueries.entry(for: newToken)
    }
}
