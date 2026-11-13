// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

enum FocusedAdmissionAttempt: Equatable {
    case handled
    case admissionPending(WindowAdmissionPendingReason, verifiedManagedParentToken: WindowToken?)
    case admissionRejected(WindowAdmissionRejectionReason, verifiedManagedParentToken: WindowToken?)
    case rejected(verifiedManagedParentToken: WindowToken?)

    var verifiedManagedParentToken: WindowToken? {
        switch self {
        case .handled:
            nil
        case let .admissionPending(_, token),
             let .admissionRejected(_, token),
             let .rejected(token):
            token
        }
    }
}

private enum FocusedCreatePreparationOutcome {
    case prepared(AXEventHandler.PreparedCreate)
    case finished(FocusedAdmissionAttempt)
}

extension AXEventHandler {
    func admitFocusedWindowBeforeExternalFocusFallback(
        identity: AXManagedWindowIdentity,
        facts: ActivationFacts,
        requestDisposition: ActivationRequestDisposition,
        appFullscreen: Bool,
        allowsSelectedParentBorderContinuity: Bool
    )
        -> FocusedAdmissionAttempt
    {
        let token = identity.token
        let axRef = identity.axRef
        guard let controller,
              let windowId = UInt32(exactly: token.windowId)
        else {
            return .rejected(verifiedManagedParentToken: nil)
        }

        let windowInfo = resolveWindowInfo(windowId)
        let verifiedManagedParentToken = allowsSelectedParentBorderContinuity
            ? verifiedSelectedManagedParentToken(for: token, childWindowInfo: windowInfo)
            : nil
        let createPlacementContext = retainedCreatePlacementContext(
            windowId: windowId,
            controller: controller
        )
        let outcome = prepareCreateCandidate(
            windowId: windowId,
            windowInfo: windowInfo,
            fallbackToken: token,
            fallbackAXRef: axRef,
            createPlacementContext: createPlacementContext
        )
        let candidate: PreparedCreate
        switch focusedCreatePreparation(
            outcome, windowId: windowId, verifiedManagedParentToken: verifiedManagedParentToken,
            callbackGeneration: facts.callbackGeneration, controller: controller
        ) {
        case let .prepared(prepared): candidate = prepared
        case let .finished(result): return result
        }
        if rejectMismatchedFocusedCreate(
            candidate,
            expectedToken: token,
            windowId: windowId,
            callbackGeneration: facts.callbackGeneration
        ) {
            return .rejected(verifiedManagedParentToken: nil)
        }

        cancelCreatedWindowRetry(windowId: windowId)
        let focusedActivation = PendingFocusedManagedActivation(
            facts: facts, requestDisposition: requestDisposition, appFullscreen: appFullscreen
        )
        return admitPreparedFocusedCreate(
            candidate, activation: focusedActivation, requestDisposition: requestDisposition,
            verifiedManagedParentToken: verifiedManagedParentToken, controller: controller
        )
    }

    private func admitPreparedFocusedCreate(
        _ candidate: PreparedCreate,
        activation focusedActivation: PendingFocusedManagedActivation,
        requestDisposition: ActivationRequestDisposition,
        verifiedManagedParentToken: WindowToken?,
        controller: WMController
    ) -> FocusedAdmissionAttempt {
        if completeLiveStructuralReplacementCreate(
            candidate,
            focusedActivation: focusedActivation
        ) {
            return finishFocusedCreateAdmission(
                candidate, activation: focusedActivation, requestDisposition: requestDisposition,
                verifiedManagedParentToken: verifiedManagedParentToken, controller: controller
            )
        }
        if shouldDelayManagedReplacementCreate(candidate) {
            enqueueManagedReplacementCreate(
                candidate,
                focusedActivation: focusedActivation
            )
            return .handled
        }

        trackPreparedCreate(candidate, countsAsFocused: true)
        return finishFocusedCreateAdmission(
            candidate, activation: focusedActivation, requestDisposition: requestDisposition,
            verifiedManagedParentToken: verifiedManagedParentToken, controller: controller
        )
    }

    private func focusedCreatePreparation(
        _ outcome: CreatePreparationOutcome,
        windowId: UInt32,
        verifiedManagedParentToken: WindowToken?,
        callbackGeneration: UInt64?,
        controller: WMController
    ) -> FocusedCreatePreparationOutcome {
        switch outcome {
        case let .prepared(prepared):
            return .prepared(prepared)
        case let .alreadyTracked(trackedToken):
            noteManagedWindowSubscriptionIdentityChanged()
            discardCreatePlacementContext(windowId: windowId)
            return .finished(controller.workspaceManager.entry(for: trackedToken) == nil
                ? .rejected(verifiedManagedParentToken: verifiedManagedParentToken)
                : .handled)
        case .identityRebindPending:
            return .finished(.handled)
        case let .pending(pendingToken, pendingAXRef, reason):
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionPending,
                    pid: pendingToken?.pid,
                    windowId: Int(windowId),
                    bundleId: pendingToken.flatMap { resolveBundleId($0.pid) },
                    reason: reason.rawValue,
                    callbackGeneration: callbackGeneration,
                    axRef: pendingAXRef
                )
            )
            return .finished(.admissionPending(reason, verifiedManagedParentToken: verifiedManagedParentToken))
        case let .ignored(ignoredToken, reason):
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionIgnored,
                    pid: ignoredToken?.pid,
                    windowId: Int(windowId),
                    bundleId: ignoredToken.flatMap { resolveBundleId($0.pid) },
                    reason: reason.rawValue,
                    callbackGeneration: callbackGeneration
                )
            )
            discardCreatePlacementContext(windowId: windowId)
            return .finished(.admissionRejected(reason, verifiedManagedParentToken: verifiedManagedParentToken))
        }
    }

    private func rejectMismatchedFocusedCreate(
        _ candidate: PreparedCreate,
        expectedToken token: WindowToken,
        windowId: UInt32,
        callbackGeneration: UInt64?
    ) -> Bool {
        guard candidate.token != token else { return false }
        WindowAdmissionTrace.record(
            .init(
                action: .admissionIgnored,
                pid: candidate.token.pid,
                windowId: candidate.token.windowId,
                bundleId: candidate.bundleId,
                competingPid: token.pid,
                reason: WindowAdmissionRejectionReason.invalidIdentity.rawValue,
                callbackGeneration: callbackGeneration,
                axRef: candidate.axRef
            )
        )
        releasePreparedWindowSubscription(windowId)
        discardCreatePlacementContext(windowId: windowId)
        return true
    }

    private func finishFocusedCreateAdmission(
        _ candidate: PreparedCreate,
        activation focusedActivation: PendingFocusedManagedActivation,
        requestDisposition: ActivationRequestDisposition,
        verifiedManagedParentToken: WindowToken?,
        controller: WMController
    ) -> FocusedAdmissionAttempt {
        guard let entry = controller.workspaceManager.entry(for: candidate.token) else {
            return .handled
        }

        let targetMonitor = controller.workspaceManager.monitor(for: entry.workspaceId)
        let isWorkspaceActive = targetMonitor.map { monitor in
            controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == entry.workspaceId
        } ?? false

        return completeFocusedManagedAdmission(
            entry: entry,
            isWorkspaceActive: isWorkspaceActive,
            activation: focusedActivation,
            requestDisposition: requestDisposition
        ) ? .handled : .rejected(verifiedManagedParentToken: verifiedManagedParentToken)
    }

    func scheduleFocusedAdmissionReadmit(
        continuation: FocusedAdmissionRetryContinuation,
        axRef: AXWindowRef,
        reason: WindowAdmissionPendingReason
    ) -> Bool {
        let token = continuation.token
        let source = continuation.source
        let observationGeneration = continuation.observationGeneration
        let callbackGeneration = continuation.callbackGeneration
        guard let windowId = UInt32(exactly: token.windowId) else { return false }
        return scheduleAdmissionRetry(
            windowId: windowId,
            expectedToken: token,
            axRef: axRef,
            reason: reason,
            trigger: .focused(
                token: token,
                source: source,
                observationGeneration: observationGeneration,
                callbackGeneration: callbackGeneration
            )
        )
    }

    @discardableResult
    func completeFocusedManagedAdmission(
        entry: WindowState,
        isWorkspaceActive: Bool,
        activation: PendingFocusedManagedActivation,
        requestDisposition: ActivationRequestDisposition,
        bindCurrentPidRequest: Bool = true
    ) -> Bool {
        guard let controller else { return false }
        if shouldSuppressObservedManagedActivation(
            entry: entry,
            requestDisposition: requestDisposition,
            source: activation.source,
            origin: activation.origin,
            observationGeneration: activation.observationGeneration
        ) {
            if case let .conflictsWithPendingRequest(request) = requestDisposition {
                continueManagedFocusRequest(
                    request,
                    source: activation.source,
                    origin: activation.origin,
                    reason: .pendingFocusUnmanagedToken
                )
            }
            return true
        }

        switch requestDisposition {
        case .matchesActiveRequest:
            break
        case let .conflictsWithPendingRequest(request):
            resolveConflictingFocusedAdmission(
                request,
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                activation: activation
            )
            return true
        case .unrelatedNoRequest:
            guard acceptsUnrequestedFocusedAdmission(
                entry,
                isWorkspaceActive: isWorkspaceActive,
                activation: activation,
                controller: controller
            ) else { return true }
        }

        handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: isWorkspaceActive,
            appFullscreen: activation.appFullscreen,
            source: activation.source,
            confirmRequest: true,
            origin: activation.origin,
            activeRequestId: activation.request.requestId,
            bindCurrentPidRequest: bindCurrentPidRequest,
            callbackGeneration: activation.callbackGeneration
        )
        return true
    }

    private func resolveConflictingFocusedAdmission(
        _ request: ManagedFocusRequest,
        entry: WindowState,
        isWorkspaceActive: Bool,
        activation: PendingFocusedManagedActivation
    ) {
        if shouldHonorObservedFocusOverPendingRequest(
            observedToken: entry.token,
            source: activation.source,
            origin: activation.origin
        ) {
            clearManagedFocusState(
                matching: request.token,
                workspaceId: request.workspaceId
            )
            handleManagedAppActivation(
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                appFullscreen: activation.appFullscreen,
                source: activation.source,
                confirmRequest: true,
                origin: activation.origin,
                activeRequestId: nil,
                bindCurrentPidRequest: false,
                callbackGeneration: activation.callbackGeneration
            )
            return
        }
        continueManagedFocusRequest(
            request,
            source: activation.source,
            origin: activation.origin,
            reason: .pendingFocusUnmanagedToken
        )
    }

    private func acceptsUnrequestedFocusedAdmission(
        _ entry: WindowState,
        isWorkspaceActive: Bool,
        activation: PendingFocusedManagedActivation,
        controller: WMController
    ) -> Bool {
        if activation.origin == .retry,
           controller.workspaceManager.externalFocusToken != entry.token,
           frontmostApplicationPIDProvider() != entry.pid
        {
            return false
        }
        return shouldHandleObservedManagedActivationWithoutPendingRequest(
            source: activation.source,
            origin: activation.origin,
            isWorkspaceActive: isWorkspaceActive
        )
    }
}
