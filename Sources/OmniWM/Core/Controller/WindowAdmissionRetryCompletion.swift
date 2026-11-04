// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension AXEventHandler {
    @discardableResult
    func finishAdmissionRetryAfterTracking(windowId: UInt32) -> Bool {
        finishAdmissionRetry(windowId: windowId)
    }

    func finishRuleReevaluationAfterTracking(
        windowId: UInt32,
        wasNewlyManaged: Bool
    ) {
        let completedSubscriptionIdentityTransition = finishAdmissionRetryAfterTracking(
            windowId: windowId
        )
        if wasNewlyManaged, !completedSubscriptionIdentityTransition {
            noteManagedWindowSubscriptionIdentityChanged()
        }
    }

    func finishAdmissionRetryAfterCollision(
        windowId: UInt32,
        token: WindowToken,
        axRef: AXWindowRef
    ) {
        guard let state = admissionRetryStateByWindowId[windowId],
              state.expectedToken.map({ $0 == token }) ?? true,
              state.axRef.map({ CFEqual($0.element, axRef.element) }) ?? true
        else {
            return
        }
        if case .identityRebind = state.trigger { return }
        _ = finishAdmissionRetry(windowId: windowId)
    }

    func ownsFocusedAdmissionRetryExecution(_ execution: AdmissionRetryExecution) -> Bool {
        guard let state = admissionRetryStateByWindowId[execution.windowId],
              state.generation == execution.generation,
              state.executionPhase == .running(execution.executionOwner),
              case let .focused(token, _, _, _) = state.trigger,
              token.windowId == Int(execution.windowId)
        else {
            return false
        }
        return true
    }

    func ownsFocusedAdmissionRetryExecution(
        _ execution: AdmissionRetryExecution,
        matching facts: ActivationFacts
    ) -> Bool {
        guard ownsFocusedAdmissionRetryExecution(execution),
              let state = admissionRetryStateByWindowId[execution.windowId],
              case let .focused(token, source, observationGeneration, callbackGeneration) = state.trigger
        else {
            return false
        }
        return facts.origin == .retry
            && facts.pid == token.pid
            && facts.source == source
            && facts.observationGeneration == observationGeneration
            && facts.callbackGeneration == callbackGeneration
    }

    @discardableResult
    func finishFocusedAdmissionRetryExecution(_ execution: AdmissionRetryExecution) -> Bool {
        guard ownsFocusedAdmissionRetryExecution(execution),
              let state = admissionRetryStateByWindowId.removeValue(forKey: execution.windowId)
        else {
            return false
        }
        state.task?.cancel()
        completeAdmissionRetrySubscriptionOwnership(
            windowId: execution.windowId,
            state: state
        )
        finishDeferredReplacementAfterTracking(windowId: execution.windowId)
        return true
    }

    private func finishAdmissionRetry(windowId: UInt32) -> Bool {
        guard var state = admissionRetryStateByWindowId[windowId] else {
            finishDeferredReplacementAfterTracking(windowId: windowId)
            return false
        }
        if let executionOwner = state.focusedAdmissionReplayExecutionOwner,
           state.executionPhase == .running(executionOwner)
        {
            return false
        }
        state.task?.cancel()
        let completedSubscriptionIdentityTransition = completeAdmissionRetrySubscriptionOwnership(
            windowId: windowId,
            state: state
        )
        state.preparedSubscriptionRetainCount = 0
        finishDeferredReplacementAfterTracking(windowId: windowId)
        guard let continuation = state.focusedAdmissionContinuation
            ?? state.trigger.focusedAdmissionContinuation
        else {
            admissionRetryStateByWindowId.removeValue(forKey: windowId)
            return completedSubscriptionIdentityTransition
        }
        let executionOwner = nextAdmissionRetryExecutionOwner
        nextAdmissionRetryExecutionOwner &+= 1
        state.task = nil
        state.trigger = .focused(
            token: continuation.token,
            source: continuation.source,
            observationGeneration: continuation.observationGeneration,
            callbackGeneration: continuation.callbackGeneration
        )
        state.identityRebindSource = nil
        state.focusedAdmissionContinuation = continuation
        state.executionPhase = .running(executionOwner)
        state.focusedAdmissionReplayExecutionOwner = executionOwner
        admissionRetryStateByWindowId[windowId] = state
        let execution = AdmissionRetryExecution(
            windowId: windowId,
            generation: state.generation,
            executionOwner: executionOwner
        )
        requestFocusedAdmissionFacts(continuation: continuation, execution: execution)
        return completedSubscriptionIdentityTransition
    }

    func hasLiveFocusedAdmissionContinuation(for token: WindowToken) -> Bool {
        guard let windowId = UInt32(exactly: token.windowId),
              let state = admissionRetryStateByWindowId[windowId],
              !state.exhausted,
              let continuation = state.focusedAdmissionContinuation
              ?? state.trigger.focusedAdmissionContinuation,
              continuation.token == token,
              isCurrentFocusedAdmissionContinuation(continuation)
        else {
            return false
        }
        switch state.executionPhase {
        case .waiting:
            return state.task != nil
        case .queued:
            return true
        case .running:
            return true
        }
    }

    func cancelTrackedTilingPromotionRetry(windowId: Int) {
        guard let windowId = UInt32(exactly: windowId),
              let state = admissionRetryStateByWindowId[windowId],
              case .ruleReevaluation = state.trigger
        else {
            return
        }
        cancelCreatedWindowRetry(windowId: windowId)
        finishDeferredReplacementAfterTracking(windowId: windowId)
    }

    func retireStaleFocusedAdmissionRetry(pid: pid_t, observationGeneration: UInt64) {
        for windowId in Array(admissionRetryStateByWindowId.keys) {
            guard var state = admissionRetryStateByWindowId[windowId],
                  let continuation = state.focusedAdmissionContinuation
                  ?? state.trigger.focusedAdmissionContinuation,
                  continuation.token.pid == pid,
                  continuation.observationGeneration == observationGeneration
            else {
                continue
            }
            if case .focused = state.trigger {
                cancelCreatedWindowRetry(windowId: windowId)
                finishDeferredReplacementAfterTracking(windowId: windowId)
            } else {
                state.focusedAdmissionContinuation = nil
                admissionRetryStateByWindowId[windowId] = state
            }
        }
    }

    func cleanupAdmissionStateForTerminatedApp(pid: pid_t) {
        let retryWindowIds = admissionRetryStateByWindowId.compactMap { windowId, state -> UInt32? in
            guard state.expectedToken?.pid == pid
                || state.trigger.protectionPIDs.contains(pid)
                || state.axRef.flatMap(AXWindowService.processIdentifier) == pid
                || identityAliasesByWindowId[Int(windowId)]?.contains(pid: pid) == true
                || resolveWindowInfo(windowId).map({ pid_t($0.pid) == pid }) == true
            else {
                return nil
            }
            return windowId
        }
        for windowId in retryWindowIds {
            cleanupAdmissionRetryForTerminatedApp(windowId: windowId, pid: pid)
        }
        pruneDeferredReplacementProtections(forTerminatedPID: pid)

        for windowId in Array(identityAliasesByWindowId.keys) {
            guard var history = identityAliasesByWindowId[windowId] else { continue }
            history.remove(pid: pid)
            if history.isEmpty {
                identityAliasesByWindowId.removeValue(forKey: windowId)
            } else {
                identityAliasesByWindowId[windowId] = history
            }
        }
    }

    private func cleanupAdmissionRetryForTerminatedApp(windowId: UInt32, pid: pid_t) {
        if WindowAdmissionTrace.shared.isActive,
           let state = admissionRetryStateByWindowId[windowId]
        {
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionDisappeared,
                    pid: state.expectedToken?.pid ?? pid,
                    windowId: Int(windowId),
                    reason: "process_terminated",
                    attempt: state.attempt,
                    retryGeneration: state.generation,
                    axRef: state.axRef
                )
            )
        }
        cancelCreatedWindowRetry(windowId: windowId)
        discardCreatePlacementContext(windowId: windowId)
        removeDeferredCreatedWindow(windowId)
        discardDeferredReplacementProtection(windowId: windowId)
    }

    @discardableResult
    func cancelCreatedWindowRetry(windowId: UInt32) -> Int {
        guard let state = admissionRetryStateByWindowId.removeValue(forKey: windowId) else { return 0 }
        state.task?.cancel()
        completeAdmissionRetrySubscriptionOwnership(windowId: windowId, state: state)
        cancelSameAppCloseProbe(for: state.trigger, reason: "identity_rebind_retry_cancelled")
        if let source = state.identityRebindSource {
            resumeQueuedIdentityRebind(for: source.handle)
        }
        return state.preparedSubscriptionRetainCount
    }

    func cancelCreatedWindowRetry(windowId: Int) {
        guard let windowId = UInt32(exactly: windowId) else { return }
        cancelCreatedWindowRetry(windowId: windowId)
    }

    func resetCreatedWindowRetryState() {
        for (windowId, state) in admissionRetryStateByWindowId {
            state.task?.cancel()
            completeAdmissionRetrySubscriptionOwnership(windowId: windowId, state: state)
            cancelSameAppCloseProbe(for: state.trigger, reason: "identity_rebind_retry_reset")
        }
        admissionRetryStateByWindowId.removeAll()
        deferredReplacementProtectionsByWindowId.removeAll()
        cancelFocusLossRescans()
    }

    func cancelSameAppCloseProbe(
        for trigger: AdmissionRetryTrigger,
        reason: String
    ) {
        guard case let .identityRebind(oldWindow, _, _, _, _) = trigger else { return }
        cancelSameAppCloseProbe(
            matchingFocusedToken: oldWindow.token,
            reason: reason
        )
    }

    @discardableResult
    func completeAdmissionRetrySubscriptionOwnership(
        windowId: UInt32,
        state: AdmissionRetryState
    ) -> Bool {
        if releasePreparedWindowSubscriptions(
            windowId,
            count: state.preparedSubscriptionRetainCount
        ) {
            return true
        }
        guard case .identityRebind = state.trigger else { return false }
        noteManagedWindowSubscriptionIdentityChanged()
        return true
    }

    func admissionIncarnationRelation(
        _ current: AXWindowRef?,
        _ observed: AXWindowRef?,
        windowId: Int
    ) -> AdmissionIncarnationRelation {
        switch (current, observed) {
        case (nil, nil),
             (_?, nil):
            .same
        case (nil, _?):
            .bindsIdentity
        case let (current?, observed?):
            if CFEqual(current.element, observed.element) {
                .same
            } else if identityAliasesByWindowId[windowId]?.contains(current, and: observed) == true {
                .same
            } else {
                .replacement
            }
        }
    }
}
