// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
extension AXEventHandler {
    func finishManagedWindowIdentityRebind(
        rebind: ManagedWindowIdentityRebind, entry: WindowState, windowId: UInt32,
        directPreparedSubscriptionRetainCount: Int?
    ) {
        let oldWindow = rebind.oldWindow
        let newWindow = rebind.newWindow
        let managedReplacementMetadata = rebind.managedReplacementMetadata
        let admissionHints = rebind.admissionHints
        guard let controller else { return }
        let completesPendingManagedReplacement = admissionRetryStateByWindowId[windowId].map { state in
            guard !state.exhausted,
                  case let .identityRebind(retryOld, retryNew, metadata, _, _) = state.trigger
            else {
                return false
            }
            return retryOld.token == oldWindow.token
                && retryNew.token == newWindow.token
                && metadata != nil
        } ?? false
        if let admissionHints {
            _ = controller.workspaceManager.updateAdmissionHints(admissionHints, for: newWindow.token)
        }
        if let workspaceId = managedReplacementMetadata?.workspaceId {
            rekeyManagedReplacementFocusTransaction(
                from: oldWindow.token,
                to: newWindow.token,
                workspaceId: workspaceId
            )
        }

        completeReboundWindowAdmission(
            windowId: windowId, directPreparedSubscriptionRetainCount: directPreparedSubscriptionRetainCount
        )
        let closeProbe = cancelSameAppCloseProbe(
            matchingFocusedToken: oldWindow.token,
            reason: "identity_rebind"
        )
        clearTerminalFrameFailure(windowId: oldWindow.token.windowId)
        admissionQuarantineByWindowId.removeValue(forKey: oldWindow.token.windowId)
        identityAliasesByWindowId.removeValue(forKey: oldWindow.token.windowId)
        AXWindowService.invalidateCachedTitles(windowIds: [UInt32(oldWindow.token.windowId), windowId])
        scheduleWindowRuleReevaluationIfNeeded(targets: [.window(entry.token)])
        traceManagedWindowIdentityRebind(rebind, entry: entry)
        controller.requestWorkspaceBarRefresh()
        controller.surfaceReconciler.noteRestackOccurred()
        if completesPendingManagedReplacement,
           let closeProbe
        {
            handleSameAppCloseProbeDeadline(closeProbe, focusedToken: newWindow.token)
        }
    }

    private func completeReboundWindowAdmission(
        windowId: UInt32, directPreparedSubscriptionRetainCount: Int?
    ) {
        let completedStateSubscriptionIdentityTransition = finishAdmissionRetryAfterTracking(
            windowId: windowId
        )
        discardCreatePlacementContext(windowId: windowId)
        if let directPreparedSubscriptionRetainCount {
            if directPreparedSubscriptionRetainCount > 0 {
                releasePreparedWindowSubscriptions(
                    windowId,
                    count: directPreparedSubscriptionRetainCount
                )
            } else if !completedStateSubscriptionIdentityTransition {
                noteManagedWindowSubscriptionIdentityChanged()
            }
        }
    }

    private func traceManagedWindowIdentityRebind(
        _ rebind: ManagedWindowIdentityRebind, entry: WindowState
    ) {
        let oldWindow = rebind.oldWindow
        let newWindow = rebind.newWindow
        let managedReplacementMetadata = rebind.managedReplacementMetadata
        WindowAdmissionTrace.record(
            .init(
                action: .admissionReplaced,
                pid: entry.pid,
                windowId: entry.windowId,
                bundleId: NSRunningApplication(processIdentifier: entry.pid)?.bundleIdentifier,
                competingPid: oldWindow.token.pid,
                reason: managedReplacementMetadata == nil
                    ? "identity_rekeyed"
                    : "structural_managed_replacement",
                outcome: "oldWindowId=\(oldWindow.token.windowId)",
                axRef: newWindow.axRef
            )
        )
    }

    func commitManagedWindowIdentityRebind(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        axRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata?
    ) -> WindowState? {
        guard let controller else { return nil }
        if oldToken.pid != newToken.pid,
           let request = controller.intentLedger.activeManagedRequest,
           case let .awaitingSameAppActivation(sourceToken, _) = request.phase,
           request.token == oldToken || sourceToken == oldToken
        {
            controller.cancelManagedFocusRequestAndRestoreSource(request)
        }
        let focusTransactionIds = controller.dwindleLayoutHandler
            .groupReveals.currentPendingGroupRevealFocusTransactionIds(for: oldToken)
        return controller.withRuntimeFrameJobCancellationSuppressed {
            guard let entry = controller.workspaceManager.rekeyWindow(
                from: oldToken,
                to: newToken,
                newAXRef: axRef,
                managedReplacementMetadata: managedReplacementMetadata
            )
            else {
                return nil
            }

            let markRekeyResult = controller.windowMarkRegistry.rekey(from: oldToken, to: newToken)
            if markRekeyResult == .conflict {
                Log.reconcile.error("Runtime window mark rekey conflict from \(oldToken) to \(newToken)")
            }
            controller.intentLedger.rekeyManagedRequest(from: oldToken, to: newToken)
            controller.rekeyScratchpadWindowResources(from: oldToken, to: newToken, axRef: axRef)
            controller.layoutRefreshController.rekeyPendingRevealTransaction(
                from: oldToken,
                to: newToken,
                entry: entry
            )
            controller.layoutRefreshController.rekeyNativeFullscreenRestoredFrameApply(
                from: oldToken,
                to: newToken
            )
            controller.dwindleLayoutHandler.groupReveals.rekeyPendingGroupRevealTransaction(
                from: oldToken,
                to: newToken,
                entry: entry,
                rebasingFocusTransactionIds: focusTransactionIds
            )
            return entry
        }
    }
}
