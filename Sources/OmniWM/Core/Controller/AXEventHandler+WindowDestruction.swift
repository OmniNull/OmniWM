// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    func hasPendingWindowClose(_ token: WindowToken, workspaceId: WorkspaceDescriptor.ID) -> Bool {
        if hasPendingManagedReplacementDestroy(token, workspaceId: workspaceId, evidence: .windowClosed) {
            return true
        }
        return admissionRetryStateByWindowId.values.contains { state in
            guard let source = state.identityRebindSource,
                  source.closedToken == token
            else { return false }
            return controller?.workspaceManager.handle(for: token) === source.handle
        }
    }

    private func prepareDestroyCandidate(
        windowInfo: WindowServerInfo?,
        token: WindowToken?,
        evidence: WindowDestroyEvidence
    ) -> PreparedDestroy? {
        guard let controller else { return nil }
        guard let token,
              let entry = controller.workspaceManager.entry(for: token)
        else {
            return nil
        }

        let bundleId = resolveBundleId(token.pid) ?? entry.managedReplacementMetadata?.bundleId
        let windowInfo = WMController.exactWindowServerInfo(windowInfo, for: token)
        let cachedMetadata = overlayWindowServerInfo(
            windowInfo,
            onto: cachedManagedReplacementMetadata(
                for: entry,
                fallbackBundleId: bundleId
            )
        )
        let replacementMetadata: ManagedReplacementMetadata
        if managedReplacementNeedsLiveAXFacts(cachedMetadata) {
            let facts = managedReplacementFacts(
                for: entry.axRef,
                pid: token.pid,
                bundleId: cachedMetadata.bundleId,
                windowInfo: windowInfo,
                includeTitle: false
            )
            let liveMetadata = makeManagedReplacementMetadata(
                bundleId: cachedMetadata.bundleId,
                workspaceId: entry.workspaceId,
                mode: entry.mode,
                facts: facts
            )
            replacementMetadata = cachedMetadata.mergingNonNilValues(from: liveMetadata)
        } else {
            replacementMetadata = cachedMetadata
        }

        return PreparedDestroy(
            token: token,
            replacementMetadata: replacementMetadata,
            evidence: evidence
        )
    }

    func handleWindowDestroyed(
        windowId: UInt32,
        pidHint: pid_t?,
        expectedWindow: AXWindowRef? = nil,
        callbackGeneration: UInt64? = nil,
        evidence: WindowDestroyEvidence
    ) {
        handleWindowDestroyed(
            windowId: windowId, pidHint: pidHint, expectedWindow: expectedWindow,
            callbackGeneration: callbackGeneration, evidence: evidence, windowInfo: resolveWindowInfo(windowId)
        )
    }

    func handleWindowDestroyed(
        windowId: UInt32,
        pidHint: pid_t?,
        expectedWindow: AXWindowRef? = nil,
        callbackGeneration: UInt64? = nil,
        evidence: WindowDestroyEvidence,
        windowInfo: WindowServerInfo?
    ) {
        let identityResolution = WindowServerIdentityResolution(windowId: windowId, info: windowInfo)
        let trackedToken = resolveTrackedTokenForDestruction(
            windowId,
            pidHint: pidHint,
            identityResolution: identityResolution
        )
        let resolvedToken = trackedToken
            ?? identityResolution.token
            ?? pidHint.map { WindowToken(pid: $0, windowId: Int(windowId)) }
        WindowAdmissionTrace.record(
            .init(
                action: .admissionDestroyed,
                pid: resolvedToken?.pid ?? pidHint,
                windowId: Int(windowId),
                bundleId: resolvedToken.flatMap { resolveBundleId($0.pid) },
                reason: resolvedToken == nil ? "unresolved_identity" : "resolved_identity",
                callbackGeneration: callbackGeneration,
                axRef: resolvedToken.flatMap {
                    controller?.workspaceManager.entry(for: $0)?.axRef
                }
            )
        )

        guard let candidate = prepareDestroyCandidate(
            windowInfo: windowInfo,
            token: trackedToken,
            evidence: evidence
        ) else {
            retireUnmanagedWindowDestruction(
                .init(
                    windowId: windowId,
                    pidHint: pidHint,
                    expectedWindow: expectedWindow,
                    callbackGeneration: callbackGeneration,
                    resolvedToken: resolvedToken,
                    identityResolution: identityResolution
                )
            )
            return
        }

        let shouldDelayDestroy = shouldDelayManagedReplacementDestroy(candidate)
        if shouldDelayDestroy,
           handleNativeFullscreenDestroy(candidate.token, evidence: candidate.evidence)
        {
            return
        }
        if shouldDelayDestroy {
            enqueueManagedReplacementDestroy(candidate)
            return
        }

        processPreparedDestroy(candidate)
    }

    private struct UnmanagedWindowDestruction {
        let windowId: UInt32
        let pidHint: pid_t?
        let expectedWindow: AXWindowRef?
        let callbackGeneration: UInt64?
        let resolvedToken: WindowToken?
        let identityResolution: WindowServerIdentityResolution
    }

    private func retireUnmanagedWindowDestruction(_ destruction: UnmanagedWindowDestruction) {
        let windowId = destruction.windowId
        let pidHint = destruction.pidHint
        let expectedWindow = destruction.expectedWindow
        let callbackGeneration = destruction.callbackGeneration
        let resolvedToken = destruction.resolvedToken
        let identityResolution = destruction.identityResolution
        discardUnmanagedDestroyedWindowState(windowId: windowId, resolvedToken: resolvedToken)
        WindowAdmissionTrace.record(
            .init(
                action: .admissionDisappeared,
                pid: resolvedToken?.pid ?? pidHint,
                windowId: Int(windowId),
                reason: "destroy_without_managed_candidate",
                callbackGeneration: callbackGeneration
            )
        )
        clearFocusedTargetForDestroyedWindow(
            windowId: windowId,
            resolvedToken: resolvedToken,
            pidHint: pidHint,
            identityResolution: identityResolution
        )
        if let controller,
           controller.workspaceManager.entry(forWindowId: Int(windowId)) == nil
        {
            if let expectedWindow,
               let pid = pidHint ?? resolvedToken?.pid
            {
                controller.axManager.removeWindowState(pid: pid, expectedWindow: expectedWindow)
            } else if let resolvedToken {
                controller.axManager.removeWindowLedgerState(
                    pid: resolvedToken.pid,
                    windowId: resolvedToken.windowId
                )
                controller.axManager.bindManagedWindows(
                    controller.workspaceManager.entries(forPid: resolvedToken.pid)
                )
            }
        }
        if let resolvedToken {
            scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(resolvedToken.pid)])
        } else if let pid = pidHint {
            scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(pid_t(pid))])
        }
    }

    private func discardUnmanagedDestroyedWindowState(
        windowId: UInt32,
        resolvedToken: WindowToken?
    ) {
        identityAliasesByWindowId.removeValue(forKey: Int(windowId))
        admissionQuarantineByWindowId.removeValue(forKey: Int(windowId))
        clearTerminalFrameFailure(windowId: Int(windowId))
        guard let resolvedToken else { return }
        cancelCreatedWindowRetry(windowId: windowId)
        controller?.clearManualWindowOverride(for: resolvedToken)
        cancelSameAppCloseProbe(matchingFocusedToken: resolvedToken, reason: "destroy_resolved")
    }

    private func clearFocusedTargetForDestroyedWindow(
        windowId: UInt32,
        resolvedToken: WindowToken?,
        pidHint: pid_t?,
        identityResolution: WindowServerIdentityResolution
    ) {
        guard let controller,
              let target = controller.workspaceManager.externalFocusToken
        else { return }

        let matchesResolvedToken = resolvedToken.map { $0 == target } ?? false
        let matchesPidHint = pidHint.map { $0 == target.pid && target.windowId == Int(windowId) } ?? false
        let matchesWindowId = if case .unavailable = identityResolution {
            target.windowId == Int(windowId)
        } else {
            false
        }
        guard matchesResolvedToken || matchesPidHint || matchesWindowId else { return }

        controller.workspaceManager.clearExternalFocusIdentity(matching: target)
    }

    func processPreparedDestroy(_ candidate: PreparedDestroy) {
        handleRemoved(token: candidate.token, evidence: candidate.evidence)
        clearManagedReplacementFocusTransaction(
            containing: candidate.token,
            workspaceId: candidate.workspaceId,
            reason: "destroy_processed"
        )
    }

    func shouldDelayManagedReplacementDestroy(_ candidate: PreparedDestroy) -> Bool {
        managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) != nil
    }
}
