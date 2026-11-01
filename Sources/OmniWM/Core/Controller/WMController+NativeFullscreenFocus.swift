// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension WMController {
    func activateNativeFullscreenPlaceholder(_ originalToken: WindowToken) {
        guard let record = suspendedNativeFullscreenRecord(originalToken) else { return }
        let currentToken = record.currentToken
        guard let entry = workspaceManager.entry(for: currentToken) else {
            traceNativeFullscreenActivationRejected(record, reason: .entryMissing)
            return
        }
        guard !isManagedWindowSuppressedByMacOS(currentToken) else {
            traceNativeFullscreenActivationRejected(record, reason: .appHidden)
            return
        }
        guard workspaceManager.showsNativeFullscreenPlaceholder(for: currentToken) else {
            traceNativeFullscreenActivationRejected(record, reason: .placeholderUnavailable)
            return
        }
        guard !isLockScreenActive else {
            traceNativeFullscreenActivationRejected(record, reason: .lockScreen)
            return
        }
        if hasStartedServices {
            guard !isFrontmostAppLockScreen() else {
                traceNativeFullscreenActivationRejected(record, reason: .lockScreen)
                return
            }
        }
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .activationResolved,
                originalToken: originalToken,
                currentToken: currentToken,
                workspaceId: record.workspaceId,
                transition: .init(record.transition),
                generation: record.transitionGeneration,
                reason: .accepted
            )
        )
        selectNativeFullscreenPlaceholder(entry)
        if let axRef = entry.axRef {
            performWindowFronting(pid: entry.pid, windowId: entry.windowId, axRef: axRef)
        }
    }

    private func traceNativeFullscreenActivationRejected(
        _ record: WorkspaceManager.NativeFullscreenRecord,
        reason: NativeFullscreenPlaceholderTrace.Reason
    ) {
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .activationRejected,
                originalToken: record.originalToken,
                currentToken: record.currentToken,
                workspaceId: record.workspaceId,
                transition: .init(record.transition),
                generation: record.transitionGeneration,
                reason: reason
            )
        )
    }

    @discardableResult
    func selectNativeFullscreenPlaceholder(_ entry: WindowState) -> Bool {
        let token = entry.token
        let changed = workspaceManager.selectNativeFullscreenPlaceholder(
            token,
            in: entry.workspaceId,
            onMonitor: workspaceManager.monitorId(for: entry.workspaceId)
        )
        let workspaceId = workspaceManager.workspace(for: token) ?? entry.workspaceId
        if let activeRequest = intentLedger.activeManagedRequest {
            _ = cancelManagedFocusRequest(activeRequest)
        } else {
            _ = workspaceManager.cancelCurrentManagedFocusRequest(
                matching: token,
                workspaceId: workspaceId
            )
        }
        intentLedger.discardPendingFocus(token)
        if changed {
            layoutRefreshController.requestImmediateRelayout(
                reason: .appActivationTransition,
                affectedWorkspaceIds: [workspaceId]
            )
        }
        return changed
    }

    private func suspendedNativeFullscreenRecord(_ originalToken: WindowToken) -> WorkspaceManager
        .NativeFullscreenRecord?
    {
        guard let record = workspaceManager.nativeFullscreenRecord(originalToken: originalToken) else {
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .activationRejected,
                    originalToken: originalToken,
                    reason: .recordLookupFailed
                )
            )
            return nil
        }
        guard record.transition == .suspended else {
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .activationRejected,
                    originalToken: originalToken,
                    currentToken: record.currentToken,
                    workspaceId: record.workspaceId,
                    transition: .init(record.transition),
                    generation: record.transitionGeneration,
                    reason: .transitionPending
                )
            )
            return nil
        }
        return record
    }
}
