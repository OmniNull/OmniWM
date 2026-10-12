// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    @discardableResult
    func rekeyStructuralManagedReplacement(
        match: StructuralReplacementMatch,
        identity: AXManagedWindowIdentity,
        windowId: UInt32,
        candidate: ManagedReplacementCandidateFacts,
        admissionHints: ManagedWindowAdmissionHints? = nil,
        sizeConstraints: WindowSizeConstraints? = nil
    ) -> Bool {
        let token = identity.token
        let axRef = identity.axRef
        let bundleId = candidate.bundleId
        let mode = candidate.mode
        let facts = candidate.facts
        let metadata = makeManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: match.workspaceId,
            mode: mode,
            facts: facts
        )
        let rebindResult = rekeyManagedWindowIdentity(
            from: match.token,
            to: token,
            windowId: windowId,
            axRef: axRef,
            managedReplacementMetadata: metadata,
            admissionHints: admissionHints,
            sizeConstraints: sizeConstraints
        )
        guard rebindResult.isHandled else {
            return false
        }
        return true
    }

    func managedReplacementCurrentUptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func managedReplacementPolicyName(_ policy: ManagedReplacementCorrelationPolicy) -> String {
        switch policy {
        case .structural:
            "structural"
        }
    }

    func completeLiveStructuralReplacementCreate(
        _ candidate: PreparedCreate,
        focusedActivation: PendingFocusedManagedActivation? = nil
    ) -> Bool {
        guard let match = candidate.structuralReplacementMatch,
              match.source == .liveInvisible
        else {
            return false
        }

        return rekeyManagedReplacement(
            from: match.token,
            to: candidate,
            focusedAdmissionContinuation: focusedActivation.map {
                focusedAdmissionContinuation(for: candidate.token, activation: $0)
            }
        ).isHandled
    }

    func matchedManagedReplacementPair(
        in burst: PendingManagedReplacementBurst
    ) -> MatchedManagedReplacementPair? {
        var matchedPair: MatchedManagedReplacementPair?

        for destroy in burst.destroys {
            for create in burst.creates {
                guard destroy.candidate.token != create.candidate.token,
                      managedReplacementMetadataMatches(
                          oldToken: destroy.candidate.token,
                          old: destroy.candidate.replacementMetadata,
                          new: create.candidate.replacementMetadata,
                          newFacts: nil
                      )
                else {
                    continue
                }

                if matchedPair != nil {
                    return nil
                }
                matchedPair = MatchedManagedReplacementPair(destroy: destroy, create: create)
            }
        }

        return matchedPair
    }

    private func completeManagedReplacement(
        destroy: PendingManagedDestroy,
        create: PendingManagedCreate
    ) -> ManagedWindowIdentityRebindResult {
        let result = rekeyManagedReplacement(
            from: destroy.candidate.token,
            to: create.candidate,
            focusedAdmissionContinuation: create.focusedActivation.map {
                focusedAdmissionContinuation(for: create.candidate.token, activation: $0)
            }
        )
        guard result.isHandled else {
            return result
        }
        if case .pending = result,
           destroy.candidate.evidence == .windowClosed,
           let state = admissionRetryStateByWindowId[create.candidate.windowId],
           case let .identityRebind(oldWindow, newWindow, _, _, _) = state.trigger,
           oldWindow.token == destroy.candidate.token,
           newWindow.token == create.candidate.token
        {
            admissionRetryStateByWindowId[create.candidate.windowId]?.identityRebindSource?.closedToken =
                destroy.candidate.token
        }
        completeDelayedFocusedManagedAdmission(create)
        return result
    }

    private func focusedAdmissionContinuation(
        for token: WindowToken,
        activation: PendingFocusedManagedActivation
    ) -> FocusedAdmissionRetryContinuation {
        FocusedAdmissionRetryContinuation(
            token: token,
            source: activation.source,
            observationGeneration: activation.observationGeneration,
            callbackGeneration: activation.callbackGeneration
        )
    }

    private func completeDelayedFocusedManagedAdmission(_ create: PendingManagedCreate) {
        guard let activation = create.focusedActivation,
              let controller,
              let entry = controller.workspaceManager.entry(for: create.candidate.token)
        else {
            return
        }

        let targetMonitor = controller.workspaceManager.monitor(for: entry.workspaceId)
        let isWorkspaceActive = targetMonitor.map { monitor in
            controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == entry.workspaceId
        } ?? false
        let requestDisposition: ActivationRequestDisposition
        let shouldBindCurrentPidRequest: Bool
        switch activation.request {
        case let .matchesActiveRequest(requestId):
            if let request = controller.intentLedger.activeManagedRequest(requestId: requestId) {
                requestDisposition = .matchesActiveRequest(request)
                shouldBindCurrentPidRequest = true
            } else {
                requestDisposition = .unrelatedNoRequest
                shouldBindCurrentPidRequest = false
            }
        case let .conflictsWithPendingRequest(requestId):
            if let request = controller.intentLedger.activeManagedRequest(requestId: requestId) {
                requestDisposition = .conflictsWithPendingRequest(request)
                shouldBindCurrentPidRequest = true
            } else {
                requestDisposition = .unrelatedNoRequest
                shouldBindCurrentPidRequest = false
            }
        case .unrelatedNoRequest:
            requestDisposition = .unrelatedNoRequest
            shouldBindCurrentPidRequest = false
        }
        completeFocusedManagedAdmission(
            entry: entry,
            isWorkspaceActive: isWorkspaceActive,
            activation: activation,
            requestDisposition: requestDisposition,
            bindCurrentPidRequest: shouldBindCurrentPidRequest
        )
    }

    private func replayManagedReplacementEvents(_ events: [PendingManagedReplacementEvent]) {
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            switch event {
            case let .create(create):
                trackPreparedCreate(create.candidate)
                completeDelayedFocusedManagedAdmission(create)
            case let .destroy(destroy):
                processPreparedDestroy(destroy.candidate)
            }
        }
    }

    private func rekeyManagedReplacement(
        from oldToken: WindowToken,
        to create: PreparedCreate,
        focusedAdmissionContinuation: FocusedAdmissionRetryContinuation? = nil
    ) -> ManagedWindowIdentityRebindResult {
        rekeyManagedWindowIdentity(
            from: oldToken,
            to: create.token,
            windowId: create.windowId,
            axRef: create.axRef,
            managedReplacementMetadata: create.replacementMetadata,
            admissionHints: create.admissionHints,
            preparedSubscriptionRetainContribution: 1,
            focusedAdmissionContinuation: focusedAdmissionContinuation
        )
    }

    private func completeMatchedReplacementBurst(
        _ burst: PendingManagedReplacementBurst, pair: MatchedManagedReplacementPair,
        key: ManagedReplacementKey, elapsedMillis: Int
    ) {
        let closeProbe = sameAppCloseProbePayload(
            matchingFocusedToken: pair.destroy.candidate.token
        )
        let result = completeManagedReplacement(destroy: pair.destroy, create: pair.create)
        switch result {
        case .committed:
            cancelSameAppCloseProbe(matchingDestroyIn: burst)
        case .pending:
            cancelSameAppCloseProbe(
                matchingDestroyIn: burst,
                excludingFocusedToken: pair.destroy.candidate.token
            )
        case .rejected:
            cancelSameAppCloseProbe(matchingDestroyIn: burst)
            replayManagedReplacementEvents(burst.orderedEvents)
            return
        }
        recordManagedReplacementTrace(
            key: key,
            kind: .matched(
                policy: managedReplacementPolicyName(burst.policy),
                elapsedMillis: elapsedMillis
            )
        )
        replayManagedReplacementEvents(
            burst.orderedEvents(excludingSequences: pair.excludedSequences)
        )
        if case .committed = result,
           let closeProbe
        {
            let focusedToken = controller?.workspaceManager.entry(for: pair.create.candidate.token) != nil
                ? pair.create.candidate.token
                : pair.destroy.candidate.token
            handleSameAppCloseProbeDeadline(closeProbe, focusedToken: focusedToken)
        }
    }

    func flushManagedReplacementBurst(for key: ManagedReplacementKey) {
        guard let burst = takeManagedReplacementBurst(for: key) else { return }
        markManagedReplacementFocusBurstClosed(for: key)
        let elapsedMillis = max(
            0,
            Int(((managedReplacementCurrentUptime() - burst.firstEventUptime) * 1000).rounded())
        )
        recordManagedReplacementTrace(
            key: key,
            kind: .flushed(
                policy: managedReplacementPolicyName(burst.policy),
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                holdCount: 0,
                elapsedMillis: elapsedMillis
            )
        )

        if let pair = matchedManagedReplacementPair(in: burst) {
            completeMatchedReplacementBurst(burst, pair: pair, key: key, elapsedMillis: elapsedMillis)
            return
        }

        cancelSameAppCloseProbe(matchingDestroyIn: burst)
        replayManagedReplacementEvents(burst.orderedEvents)
    }

    private func cancelSameAppCloseProbe(
        matchingDestroyIn burst: PendingManagedReplacementBurst,
        excludingFocusedToken excludedToken: WindowToken? = nil
    ) {
        guard let open = controller?.intentLedger.openSameAppCloseProbe(),
              open.payload.focusedToken != excludedToken,
              burst.destroys.contains(where: {
                  $0.candidate.token == open.payload.focusedToken
              })
        else {
            return
        }
        cancelSameAppCloseProbe(
            matchingFocusedToken: open.payload.focusedToken,
            reason: "managed_replacement_destroy_replayed"
        )
    }

    func recordDeferredManagedReplacementCreate(_ candidate: PreparedCreate) {
        WindowAdmissionTrace.record(
            .init(
                action: .admissionPending,
                pid: candidate.token.pid,
                windowId: candidate.token.windowId,
                bundleId: candidate.bundleId,
                reason: "managed_replacement_correlation",
                outcome: "deferred",
                axRef: candidate.axRef
            )
        )
    }

    func finishManagedReplacementEnqueue(
        _ burst: PendingManagedReplacementBurst, key: ManagedReplacementKey, resetExistingDeadline: Bool
    ) {
        if let controller,
           let token = controller.workspaceManager.borderFocusToken,
           burst.destroys.contains(where: { $0.candidate.token == token && $0.candidate.evidence == .windowClosed })
        {
            controller.surfaceReconciler.noteBorderChanged()
        }
        let policy = burst.policy
        recordManagedReplacementTrace(
            key: key,
            kind: .enqueued(
                policy: managedReplacementPolicyName(policy),
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                holdCount: 0,
                deadlineReset: resetExistingDeadline
            )
        )
        if flushManagedReplacementBurstIfUnambiguouslyMatched(for: key) {
            return
        }
        scheduleManagedReplacementFlush(
            for: key,
            policy: policy,
            resetExistingDeadline: resetExistingDeadline
        )
    }
}
