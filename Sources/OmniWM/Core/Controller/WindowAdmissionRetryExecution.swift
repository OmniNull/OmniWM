// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension AXEventHandler {
    func retryAdmissionAfterFrameChange(windowId: UInt32) -> Bool {
        dispatchAdmissionRetry(windowId: windowId)
    }

    @discardableResult
    func dispatchAdmissionRetry(windowId: UInt32) -> Bool {
        guard var state = admissionRetryStateByWindowId[windowId] else { return false }
        switch state.trigger {
        case .create,
             .candidate:
            if case .running = state.executionPhase { return true }
        default: break
        }
        if case .identityRebind = state.trigger {
            if case .running = state.executionPhase { return true }
            guard !state.exhausted, !state.identityRebindTargetDestroyed,
                  let source = state.identityRebindSource
            else { return false }
            state.task?.cancel()
            state.task = nil
            state.executionPhase = .queued
            admissionRetryStateByWindowId[windowId] = state
            guard activeIdentityRebindsByHandle[source.handle] == nil,
                  oldestIdentityRebind(for: source.handle)?.key == windowId
            else { return true }
            guard let entry = controller?.workspaceManager.entry(for: source.handle),
                  let entryAXRef = entry.axRef,
                  case let .identityRebind(_, newWindow, metadata, hints, constraints) = state.trigger
            else {
                cancelCreatedWindowRetry(windowId: windowId)
                rejectDeferredReplacement(windowId: windowId)
                requestTargetedFullRescan(for: state.trigger.protectionPIDs)
                return true
            }
            state.trigger = .identityRebind(
                oldWindow: AXManagedWindowIdentity(token: entry.token, axRef: entryAXRef),
                newWindow: newWindow,
                managedReplacementMetadata: metadata,
                admissionHints: hints,
                sizeConstraints: constraints
            )
        }
        state.task?.cancel()
        let executionOwner = nextAdmissionRetryExecutionOwner
        nextAdmissionRetryExecutionOwner &+= 1
        if let source = state.identityRebindSource {
            activeIdentityRebindsByHandle[source.handle] = executionOwner
        }
        state.executionPhase = .running(executionOwner)
        state.task = nil
        admissionRetryStateByWindowId[windowId] = state
        resumeAdmissionRetry(windowId: windowId, state: state, executionOwner: executionOwner)
        return true
    }

    private func oldestIdentityRebind(for handle: WindowHandle) -> (key: UInt32, value: AdmissionRetryState)? {
        var oldest: (key: UInt32, value: AdmissionRetryState)?
        var oldestOrder = UInt64.max
        for (windowId, state) in admissionRetryStateByWindowId {
            guard !state.exhausted, !state.identityRebindTargetDestroyed,
                  let source = state.identityRebindSource, source.handle === handle,
                  source.requestOrder < oldestOrder
            else { continue }
            oldest = (windowId, state)
            oldestOrder = source.requestOrder
        }
        return oldest
    }

    func resumeQueuedIdentityRebind(for handle: WindowHandle) {
        guard activeIdentityRebindsByHandle[handle] == nil,
              let next = oldestIdentityRebind(for: handle),
              next.value.executionPhase == .queued
        else { return }
        dispatchAdmissionRetry(windowId: next.key)
    }

    private func finishIdentityRebindExecution(for handle: WindowHandle, executionOwner: UInt64) {
        guard activeIdentityRebindsByHandle[handle] == executionOwner else { return }
        activeIdentityRebindsByHandle.removeValue(forKey: handle)
        resumeQueuedIdentityRebind(for: handle)
    }

    func retryAdmissionAfterFrameChangeRequiresEarlyReturn(windowId: UInt32) -> Bool {
        guard admissionRetryStateByWindowId[windowId] != nil else { return false }
        let wasTrackedBeforeRetry = controller?.workspaceManager.entry(forWindowId: Int(windowId)) != nil
        return retryAdmissionAfterFrameChange(windowId: windowId) && !wasTrackedBeforeRetry
    }

    private func resumeAdmissionRetry(
        windowId: UInt32,
        state: AdmissionRetryState,
        executionOwner: UInt64
    ) {
        switch state.trigger {
        case .create:
            processCreatedWindow(
                windowId: windowId,
                retryExecution: .init(
                    windowId: windowId, generation: state.generation, executionOwner: executionOwner
                )
            )
        case let .candidate(token, axRef, placementOrigin):
            processCreatedWindow(
                windowId: windowId,
                fallbackToken: token,
                fallbackAXRef: axRef,
                placementOrigin: placementOrigin,
                retryTrigger: state.trigger,
                retryExecution: .init(
                    windowId: windowId, generation: state.generation, executionOwner: executionOwner
                )
            )
        case let .focused(token, source, observationGeneration, callbackGeneration):
            let execution = AdmissionRetryExecution(
                windowId: windowId, generation: state.generation, executionOwner: executionOwner
            )
            requestFocusedAdmissionFacts(
                continuation: .init(
                    token: token,
                    source: source,
                    observationGeneration: observationGeneration,
                    callbackGeneration: callbackGeneration
                ),
                execution: execution
            )
        case .identityRebind:
            resumeIdentityRebindRetry(state: state, executionOwner: executionOwner)
        case .ruleReevaluation:
            resumeRuleReevaluationRetry(windowId: windowId, state: state, executionOwner: executionOwner)
        }
    }

    private func resumeRuleReevaluationRetry(windowId: UInt32, state: AdmissionRetryState, executionOwner: UInt64) {
        guard case let .ruleReevaluation(token, axRef, context) = state.trigger else { return }
        let task = Task { @MainActor [weak self] in
            guard let self, let controller = self.controller else { return }
            let outcome = await controller.reevaluateWindowRules(
                for: [.window(token)],
                context: context,
                stillWantsExplicitApply: {
                    self.retryStillWantsExplicitRuleApply(windowId: windowId, generation: state.generation)
                }
            )
            self.finishRuleReevaluationRetry(
                execution: .init(windowId: windowId, generation: state.generation, executionOwner: executionOwner),
                identity: .init(token: token, axRef: axRef),
                reason: state.reason,
                stale: outcome.stale
            )
        }
        var activeState = state
        activeState.task = task
        admissionRetryStateByWindowId[windowId] = activeState
    }

    private func resumeIdentityRebindRetry(state: AdmissionRetryState, executionOwner: UInt64) {
        guard case let .identityRebind(
            oldWindow,
            newWindow,
            managedReplacementMetadata,
            admissionHints,
            sizeConstraints
        ) = state.trigger else { return }
        guard let windowId = UInt32(exactly: newWindow.token.windowId) else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if let source = state.identityRebindSource {
                    self.finishIdentityRebindExecution(for: source.handle, executionOwner: executionOwner)
                }
            }
            await self.completeManagedWindowIdentityRebind(
                rebind: .init(
                    oldWindow: oldWindow,
                    newWindow: newWindow,
                    managedReplacementMetadata: managedReplacementMetadata,
                    admissionHints: admissionHints,
                    sizeConstraints: sizeConstraints
                ),
                execution: .init(windowId: windowId, generation: state.generation, executionOwner: executionOwner)
            )
        }
        var activeState = state
        activeState.task = task
        admissionRetryStateByWindowId[windowId] = activeState
    }

    func finishRuleReevaluationRetry(
        execution: AdmissionRetryExecution,
        identity: AXManagedWindowIdentity,
        reason: WindowAdmissionPendingReason,
        stale: Bool
    ) {
        let windowId = execution.windowId
        let generation = execution.generation
        let executionOwner = execution.executionOwner
        let token = identity.token
        let axRef = identity.axRef
        guard var state = admissionRetryStateByWindowId[windowId],
              state.generation == generation,
              state.executionPhase == .running(executionOwner),
              case let .ruleReevaluation(retryToken, retryAXRef, retryContext) = state.trigger,
              retryToken == token,
              CFEqual(retryAXRef.element, axRef.element)
        else {
            return
        }
        state.task = nil
        state.executionPhase = .waiting
        if stale {
            admissionRetryStateByWindowId[windowId] = state
            _ = scheduleTrackedTilingPromotionRetry(token: token, axRef: axRef, reason: reason, context: retryContext)
        } else {
            admissionRetryStateByWindowId[windowId] = state
            cancelCreatedWindowRetry(windowId: windowId)
            finishDeferredReplacementAfterTracking(windowId: windowId)
        }
    }

    func retryStillWantsExplicitRuleApply(windowId: UInt32, generation: UInt64) -> Bool {
        guard let state = admissionRetryStateByWindowId[windowId],
              state.generation == generation,
              case .ruleReevaluation(_, _, .explicitRuleApply) = state.trigger
        else {
            return false
        }
        return true
    }

    func requestFocusedAdmissionFacts(
        continuation: FocusedAdmissionRetryContinuation,
        execution: AdmissionRetryExecution
    ) {
        let factRequestIssued = handleAppActivation(
            pid: continuation.token.pid,
            source: continuation.source,
            origin: .retry,
            causalObservationGeneration: continuation.observationGeneration,
            callbackGeneration: continuation.callbackGeneration,
            focusedAdmissionRetryExecution: execution
        )
        if !factRequestIssued {
            finishFocusedAdmissionRetryExecution(execution)
        }
    }
}
