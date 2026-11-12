// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension AXEventHandler {
    var activeAdmissionRetryWindowIds: Set<Int> {
        Set(admissionRetryStateByWindowId.keys.map(Int.init))
    }

    func isOwnProcessPid(_ pid: pid_t) -> Bool {
        pid == getpid()
    }

    func scheduleGeometryAdmissionRetry(
        token: WindowToken,
        axRef: AXWindowRef,
        existingEntry: WindowState?,
        placementOrigin: WorkspacePlacementOrigin,
        context: WindowRuleReevaluationContext = .automatic
    ) {
        if let existingEntry {
            scheduleTrackedTilingPromotionRetry(
                token: existingEntry.token,
                axRef: axRef,
                reason: .degenerateGeometry,
                context: context
            )
        } else if let windowId = UInt32(exactly: token.windowId) {
            scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: token.pid,
                axRef: axRef,
                reason: .degenerateGeometry,
                placementOrigin: placementOrigin
            )
        }
    }

    @discardableResult
    func scheduleCandidateAdmissionRetry(
        windowId: UInt32,
        pid: pid_t,
        axRef: AXWindowRef,
        reason: WindowAdmissionPendingReason,
        placementOrigin: WorkspacePlacementOrigin = .liveCreate
    ) -> Bool {
        let token = WindowToken(pid: pid, windowId: Int(windowId))
        return scheduleAdmissionRetry(
            windowId: windowId,
            expectedToken: token,
            axRef: axRef,
            reason: reason,
            trigger: .candidate(
                token: token,
                axRef: axRef,
                placementOrigin: placementOrigin
            )
        )
    }

    @discardableResult
    func scheduleTrackedTilingPromotionRetry(
        token: WindowToken,
        axRef: AXWindowRef,
        reason: WindowAdmissionPendingReason,
        context: WindowRuleReevaluationContext = .automatic
    ) -> Bool {
        guard let windowId = UInt32(exactly: token.windowId) else { return false }
        let pendingTrigger = admissionRetryStateByWindowId[windowId]?.trigger
        let keepsExplicitApply = if case .ruleReevaluation(_, _, .explicitRuleApply)? = pendingTrigger { true }
        else { false }
        return scheduleAdmissionRetry(
            windowId: windowId,
            expectedToken: token,
            axRef: axRef,
            reason: reason,
            trigger: .ruleReevaluation(
                token: token,
                axRef: axRef,
                context: keepsExplicitApply ? .explicitRuleApply : context
            )
        )
    }

    func downgradeExplicitRuleApplyRetry(windowId: Int) {
        guard let windowId = UInt32(exactly: windowId),
              var state = admissionRetryStateByWindowId[windowId],
              case let .ruleReevaluation(token, axRef, .explicitRuleApply) = state.trigger
        else {
            return
        }
        state.trigger = .ruleReevaluation(token: token, axRef: axRef, context: .automatic)
        admissionRetryStateByWindowId[windowId] = state
    }

    func scheduleAdmissionRetry(
        windowId: UInt32,
        expectedToken: WindowToken?,
        axRef: AXWindowRef? = nil,
        reason: WindowAdmissionPendingReason,
        trigger: AdmissionRetryTrigger,
        preparedSubscriptionRetainContribution: Int = 0
    ) -> Bool {
        assert(preparedSubscriptionRetainContribution >= 0)
        let state = normalizedAdmissionRetryState(windowId: windowId, observedAXRef: axRef)
        if var retainedState = state,
           !retainedState.exhausted,
           retainedState.trigger.priority > trigger.priority
        {
            retainedState.focusedAdmissionContinuation = latestFocusedAdmissionRetryContinuation(
                retainedState.focusedAdmissionContinuation
                    ?? retainedState.trigger.focusedAdmissionContinuation,
                trigger.focusedAdmissionContinuation
            )
            retainedState.preparedSubscriptionRetainCount += preparedSubscriptionRetainContribution
            admissionRetryStateByWindowId[windowId] = retainedState
            return true
        }
        guard isAdmissionRetryEligible(
            windowId: windowId,
            expectedToken: expectedToken,
            trigger: trigger
        ) else {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            rejectDeferredReplacement(windowId: windowId)
            return false
        }
        let schedule = resolvedAdmissionRetrySchedule(
            state: state,
            proposal: .init(
                expectedToken: expectedToken,
                axRef: axRef,
                reason: reason,
                trigger: trigger,
                preparedSubscriptionRetainContribution: preparedSubscriptionRetainContribution
            )
        )
        if let existingResult = updateExistingAdmissionRetry(
            state,
            schedule: schedule,
            windowId: windowId
        ) {
            return existingResult
        }
        return startNextAdmissionRetry(state: state, schedule: schedule, windowId: windowId)
    }

    @discardableResult
    func retainFocusedAdmissionContinuation(
        _ continuation: FocusedAdmissionRetryContinuation,
        windowId: UInt32
    ) -> Bool {
        guard var state = admissionRetryStateByWindowId[windowId],
              !state.exhausted,
              state.expectedToken.map({ $0 == continuation.token }) ?? true
        else {
            return false
        }
        state.focusedAdmissionContinuation = latestFocusedAdmissionRetryContinuation(
            state.focusedAdmissionContinuation ?? state.trigger.focusedAdmissionContinuation,
            continuation
        )
        admissionRetryStateByWindowId[windowId] = state
        return true
    }

    private func latestFocusedAdmissionRetryContinuation(
        _ current: FocusedAdmissionRetryContinuation?,
        _ incoming: FocusedAdmissionRetryContinuation?
    ) -> FocusedAdmissionRetryContinuation? {
        guard let current else { return incoming }
        guard let incoming else { return current }
        return incoming.observationGeneration >= current.observationGeneration ? incoming : current
    }

    private func isAdmissionRetryEligible(
        windowId: UInt32,
        expectedToken: WindowToken?,
        trigger: AdmissionRetryTrigger
    ) -> Bool {
        guard let controller else { return false }
        let existingEntry = controller.workspaceManager.entry(forWindowId: Int(windowId))
        let permitsTrackedEntry = switch trigger {
        case .ruleReevaluation:
            existingEntry?.token == expectedToken && existingEntry?.mode == .floating
        case let .identityRebind(oldWindow, _, _, _, _):
            existingEntry?.token == oldWindow.token
        case .create,
             .candidate,
             .focused:
            false
        }
        return (existingEntry == nil || permitsTrackedEntry)
            && !controller.isOwnedWindow(windowNumber: Int(windowId))
            && (expectedToken.map { !isOwnProcessPid($0.pid) } ?? true)
    }

    private func normalizedAdmissionRetryState(
        windowId: UInt32,
        observedAXRef: AXWindowRef?
    ) -> AdmissionRetryState? {
        guard let state = admissionRetryStateByWindowId[windowId] else { return nil }
        let relation = admissionIncarnationRelation(
            state.axRef,
            observedAXRef,
            windowId: Int(windowId)
        )
        guard relation != .replacement,
              relation != .bindsIdentity || !state.exhausted
        else {
            cancelCreatedWindowRetry(windowId: windowId)
            return nil
        }
        return state
    }

    private func resolvedAdmissionRetrySchedule(
        state: AdmissionRetryState?,
        proposal: AdmissionRetryProposal
    ) -> AdmissionRetrySchedule {
        let expectedToken = proposal.expectedToken
        let axRef = proposal.axRef
        let reason = proposal.reason
        let trigger = proposal.trigger
        let preparedSubscriptionRetainContribution = proposal.preparedSubscriptionRetainContribution
        let preservesPriorTrigger = state.map { $0.trigger.priority > trigger.priority } ?? false
        let retainedFocusedContinuation = state.flatMap {
            $0.focusedAdmissionContinuation ?? $0.trigger.focusedAdmissionContinuation
        }
        let effectiveTrigger = preservesPriorTrigger ? state?.trigger ?? trigger : trigger
        let identityRebindSource: ManagedWindowIdentityRebindSource?
        if case let .identityRebind(oldWindow, _, _, _, _) = effectiveTrigger {
            identityRebindSource = state?.identityRebindSource
                ?? controller?.workspaceManager.handle(for: oldWindow.token).map {
                    let source = ManagedWindowIdentityRebindSource(
                        handle: $0,
                        requestOrder: nextAdmissionRetryGeneration
                    )
                    nextAdmissionRetryGeneration &+= 1
                    return source
                }
        } else {
            identityRebindSource = nil
        }
        return AdmissionRetrySchedule(
            expectedToken: preservesPriorTrigger
                ? state?.expectedToken ?? expectedToken
                : expectedToken ?? state?.expectedToken,
            axRef: preservesPriorTrigger ? state?.axRef ?? axRef : axRef ?? state?.axRef,
            reason: preservesPriorTrigger ? state?.reason ?? reason : reason,
            trigger: effectiveTrigger,
            identityRebindSource: identityRebindSource,
            focusedAdmissionContinuation: latestFocusedAdmissionRetryContinuation(
                retainedFocusedContinuation,
                trigger.focusedAdmissionContinuation
            ),
            preparedSubscriptionRetainCount: (state?.preparedSubscriptionRetainCount ?? 0)
                + preparedSubscriptionRetainContribution
        )
    }

    private func updateExistingAdmissionRetry(
        _ state: AdmissionRetryState?,
        schedule: AdmissionRetrySchedule,
        windowId: UInt32
    ) -> Bool? {
        guard var state else { return nil }
        if state.exhausted {
            releasePreparedWindowSubscriptions(
                windowId,
                count: state.preparedSubscriptionRetainCount
            )
            state.expectedToken = schedule.expectedToken
            state.axRef = schedule.axRef
            state.reason = schedule.reason
            state.trigger = schedule.trigger
            state.identityRebindSource = schedule.identityRebindSource
            state.focusedAdmissionContinuation = schedule.focusedAdmissionContinuation
            state.preparedSubscriptionRetainCount = 0
            admissionRetryStateByWindowId[windowId] = state
            rejectDeferredReplacement(windowId: windowId)
            return false
        }
        switch state.executionPhase {
        case .waiting:
            guard state.task != nil else { return nil }
        case .queued:
            break
        case .running:
            guard schedule.trigger.priority >= state.trigger.priority else { return true }
            state.task?.cancel()
            let attempt = schedule.trigger.priority == state.trigger.priority
                ? state.attempt + 1
                : state.attempt
            guard attempt <= Self.createdWindowRetryLimit else {
                exhaustAdmissionRetry(state: state, schedule: schedule, windowId: windowId)
                return false
            }
            scheduleAdmissionRetryTask(
                schedule: schedule,
                windowId: windowId,
                attempt: attempt
            )
            return true
        }
        state.expectedToken = schedule.expectedToken
        state.axRef = schedule.axRef
        state.reason = schedule.reason
        state.trigger = schedule.trigger
        state.identityRebindSource = schedule.identityRebindSource
        state.focusedAdmissionContinuation = schedule.focusedAdmissionContinuation
        state.preparedSubscriptionRetainCount = schedule.preparedSubscriptionRetainCount
        admissionRetryStateByWindowId[windowId] = state
        return !state.exhausted
    }

    private func startNextAdmissionRetry(
        state: AdmissionRetryState?,
        schedule: AdmissionRetrySchedule,
        windowId: UInt32
    ) -> Bool {
        let attempt = (state?.attempt ?? 0) + 1
        guard attempt <= Self.createdWindowRetryLimit else {
            exhaustAdmissionRetry(state: state, schedule: schedule, windowId: windowId)
            return false
        }
        scheduleAdmissionRetryTask(
            schedule: schedule,
            windowId: windowId,
            attempt: attempt
        )
        return true
    }

    private func exhaustAdmissionRetry(
        state: AdmissionRetryState?,
        schedule: AdmissionRetrySchedule,
        windowId: UInt32
    ) {
        state?.task?.cancel()
        if let state {
            completeAdmissionRetrySubscriptionOwnership(windowId: windowId, state: state)
        }
        cancelSameAppCloseProbe(
            for: schedule.trigger,
            reason: "identity_rebind_retry_exhausted"
        )
        let generation = state?.generation ?? nextAdmissionRetryGeneration
        admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: schedule.expectedToken,
            axRef: schedule.axRef,
            reason: schedule.reason,
            attempt: Self.createdWindowRetryLimit,
            generation: generation,
            trigger: schedule.trigger,
            identityRebindSource: schedule.identityRebindSource,
            focusedAdmissionContinuation: schedule.focusedAdmissionContinuation,
            exhausted: true,
            executionPhase: .waiting,
            preparedSubscriptionRetainCount: 0,
            task: nil
        )
        discardCreatePlacementContext(windowId: windowId)
        WindowAdmissionTrace.record(
            .init(
                action: .admissionRetryExhausted,
                pid: schedule.expectedToken?.pid,
                windowId: Int(windowId),
                reason: schedule.reason.rawValue,
                attempt: Self.createdWindowRetryLimit,
                retryGeneration: generation,
                axRef: schedule.axRef
            )
        )
        recordNiriCreateFocusTrace(
            .init(
                kind: .admissionRejected(
                    windowId: windowId,
                    pid: schedule.expectedToken?.pid,
                    reason: .retryExhausted
                )
            )
        )
        rejectDeferredReplacement(windowId: windowId)
        if let source = schedule.identityRebindSource {
            resumeQueuedIdentityRebind(for: source.handle)
        }
    }

    private func scheduleAdmissionRetryTask(
        schedule: AdmissionRetrySchedule,
        windowId: UInt32,
        attempt: Int
    ) {
        let generation = nextAdmissionRetryGeneration
        nextAdmissionRetryGeneration &+= 1
        var state = AdmissionRetryState(
            expectedToken: schedule.expectedToken,
            axRef: schedule.axRef,
            reason: schedule.reason,
            attempt: attempt,
            generation: generation,
            trigger: schedule.trigger,
            identityRebindSource: schedule.identityRebindSource,
            focusedAdmissionContinuation: schedule.focusedAdmissionContinuation,
            exhausted: false,
            executionPhase: .waiting,
            preparedSubscriptionRetainCount: schedule.preparedSubscriptionRetainCount,
            task: nil
        )
        state.task = makeAdmissionRetryTask(windowId: windowId, generation: generation)
        admissionRetryStateByWindowId[windowId] = state
        recordAdmissionRetryScheduled(
            schedule,
            windowId: windowId,
            attempt: attempt,
            generation: generation
        )
    }

    private func makeAdmissionRetryTask(
        windowId: UInt32,
        generation: UInt64
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stabilizationRetryDelay)
            guard !Task.isCancelled,
                  let self,
                  let state = self.admissionRetryStateByWindowId[windowId],
                  state.generation == generation
            else { return }
            self.dispatchAdmissionRetry(windowId: windowId)
        }
    }

    private func recordAdmissionRetryScheduled(
        _ schedule: AdmissionRetrySchedule,
        windowId: UInt32,
        attempt: Int,
        generation: UInt64
    ) {
        WindowAdmissionTrace.record(
            .init(
                action: .admissionRetryScheduled,
                pid: schedule.expectedToken?.pid,
                windowId: Int(windowId),
                reason: schedule.reason.rawValue,
                attempt: attempt,
                retryGeneration: generation,
                axRef: schedule.axRef
            )
        )
        recordNiriCreateFocusTrace(
            .init(
                kind: .createRetryScheduled(
                    windowId: windowId,
                    pid: schedule.expectedToken?.pid,
                    reason: schedule.reason,
                    attempt: attempt
                )
            )
        )
    }
}
