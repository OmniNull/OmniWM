// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

private struct ResolvedFocusedActivation {
    let facts: ActivationFacts
    let focusedWindow: FocusedWindowFact
    let token: WindowToken
}

extension AXEventHandler {
    func handleActivationFactsResolved(_ facts: ActivationFacts) {
        if let execution = facts.focusedAdmissionRetryExecution,
           !ownsFocusedAdmissionRetryExecution(execution, matching: facts)
        {
            return
        }
        defer {
            if let execution = facts.focusedAdmissionRetryExecution {
                finishFocusedAdmissionRetryExecution(execution)
            }
        }
        let newFocusWindowId = untrackedFocusWindowId(facts)
        defer { rescanAppThatLostFocus(newFocusWindowId: newFocusWindowId) }
        applyResolvedActivationFacts(facts)
    }

    private func applyResolvedActivationFacts(_ facts: ActivationFacts) {
        guard let controller, controller.hasStartedServices else { return }
        guard isCurrentActivationFacts(facts, controller: controller) else { return }

        let pid = facts.pid
        let axRef = facts.focusedWindow?.axRef
        let observedToken = axRef.map { canonicalObservedWindowToken(pid: pid, axRef: $0) }
        guard acceptsActivationFacts(facts, observedToken: observedToken) else { return }
        let activeRequest = controller.intentLedger.activeManagedRequest
        let requestDisposition = activationRequestDisposition(
            for: pid,
            token: observedToken,
            activeRequest: activeRequest
        )

        if let activeRequest,
           case let .awaitingSameAppActivation(sourceToken, _) = activeRequest.phase,
           facts.pid == activeRequest.token.pid,
           observedToken == nil || observedToken == sourceToken
        {
            return
        }

        guard let axRef, let focusedWindow = facts.focusedWindow else {
            handleAbsentActivationWindow(facts, requestDisposition: requestDisposition, controller: controller)
            return
        }
        let token = canonicalObservedWindowToken(pid: pid, axRef: axRef)
        let observation = ResolvedFocusedActivation(facts: facts, focusedWindow: focusedWindow, token: token)
        guard acceptsResolvedFocusedActivation(observation, controller: controller) else { return }
        controller.workspaceManager.setSystemModalFocus(focusedWindow.isSystemModalSurface ? token : nil)

        if let entry = controller.workspaceManager.entry(for: token) {
            handleTrackedActivationFacts(
                entry,
                observation: observation,
                requestDisposition: requestDisposition,
                controller: controller
            )
            return
        }

        handleUnmanagedActivationFacts(observation, requestDisposition: requestDisposition, controller: controller)
    }

    private func handleAbsentActivationWindow(
        _ facts: ActivationFacts,
        requestDisposition: ActivationRequestDisposition,
        controller: WMController
    ) {
        controller.workspaceManager.setSystemModalFocus(nil)
        handleMissingFocusedWindow(
            pid: facts.pid,
            source: facts.source,
            origin: facts.origin,
            requestDisposition: requestDisposition
        )
    }

    private func handleTrackedActivationFacts(
        _ entry: WindowState,
        observation: ResolvedFocusedActivation,
        requestDisposition: ActivationRequestDisposition,
        controller: WMController
    ) {
        let facts = observation.facts
        guard !entry.observedState.isMinimized else { return }
        if entry.observedState.isNativeWithdrawn {
            if let windowId = UInt32(exactly: entry.windowId) {
                enqueueLifecycleQuery(windowId: windowId, kind: .activation(facts))
            }
            return
        }
        let source = facts.source
        let origin = facts.origin
        let appFullscreen = observation.focusedWindow.isFullscreen
        guard let entry = restoredEntryForActivation(entry, observation: observation, controller: controller)
        else { return }
        let wsId = entry.workspaceId

        let targetMonitor = controller.workspaceManager.monitor(for: wsId)
        let isWorkspaceActive = targetMonitor.map { monitor in
            controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId
        } ?? false

        if suppressTrackedActivation(entry, observation: observation, requestDisposition: requestDisposition) { return }

        guard acceptsTrackedActivationRequest(
            observation,
            requestDisposition: requestDisposition,
            isWorkspaceActive: isWorkspaceActive
        ) else { return }

        endWindowCloseFocusRecovery(matching: wsId, reason: "accepted_managed_activation")
        handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: isWorkspaceActive,
            appFullscreen: appFullscreen,
            source: source,
            confirmRequest: true,
            origin: origin,
            callbackGeneration: facts.callbackGeneration
        )
    }

    private func handleUnmanagedActivationFacts(
        _ observation: ResolvedFocusedActivation,
        requestDisposition: ActivationRequestDisposition,
        controller: WMController
    ) {
        let facts = observation.facts
        let source = facts.source
        let token = observation.token
        let pid = facts.pid
        let axRef = observation.focusedWindow.axRef
        let focusedWindow = observation.focusedWindow
        let appFullscreen = focusedWindow.isFullscreen
        let admissionAttempt = admitFocusedWindowBeforeExternalFocusFallback(
            identity: .init(token: token, axRef: axRef),
            facts: facts,
            requestDisposition: requestDisposition,
            appFullscreen: appFullscreen,
            allowsSelectedParentBorderContinuity: !focusedWindow.isSystemModalSurface
        )
        if admissionAttempt == .handled {
            return
        }

        if deferExternalFocusForCloseRecovery(observation, requestDisposition: requestDisposition) { return }

        guard acceptsExternalActivationFallback(observation, requestDisposition: requestDisposition) else { return }

        if case let .admissionPending(reason, verifiedManagedParentToken) = admissionAttempt {
            handlePendingFocusedActivation(
                observation,
                reason: reason,
                verifiedManagedParentToken: verifiedManagedParentToken,
                controller: controller
            )
            return
        }

        _ = controller.workspaceManager.recordExternalFocus(
            pid: pid,
            windowId: token.windowId,
            verifiedManagedParentToken: admissionAttempt.verifiedManagedParentToken
        )
        controller.surfaceReconciler.noteRestackOccurred()

        recordNiriCreateFocusTrace(
            .init(
                kind: .externalFocusFallbackEntered(
                    pid: pid,
                    source: source
                )
            )
        )
    }

    private func acceptsResolvedFocusedActivation(
        _ observation: ResolvedFocusedActivation,
        controller: WMController
    ) -> Bool {
        let facts = observation.facts
        let source = facts.source
        let origin = facts.origin
        let token = observation.token
        let pid = facts.pid
        let focusedWindow = observation.focusedWindow
        if source.isAuthoritative,
           origin == .retry,
           focusedWindow.isSystemModalSurface,
           frontmostApplicationPIDProvider() != pid
        {
            return false
        }
        if let causality = facts.sameAppFocusCausality,
           controller.workspaceManager.entry(for: token) != nil,
           !hasRecentMouseFocusIntent(for: token),
           !preservesSameAppFocusCausality(causality)
        {
            return false
        }
        return true
    }

    private func restoredEntryForActivation(
        _ entry: WindowState,
        observation: ResolvedFocusedActivation,
        controller: WMController
    ) -> WindowState? {
        let token = observation.token
        let appFullscreen = observation.focusedWindow.isFullscreen
        discardCreatePlacementContext(for: token.windowId)
        if appFullscreen {
            suspendManagedWindowForNativeFullscreen(entry)
            return nil
        }
        let restoredFromNativeFullscreen = restoreManagedWindowFromNativeFullscreen(entry)
        if restoredFromNativeFullscreen,
           controller.reconcileScratchpadMemberAfterNativeFullscreenExit(entry.token)
        {
            return nil
        }
        return controller.workspaceManager.entry(for: token) ?? entry
    }

    private func suppressTrackedActivation(
        _ entry: WindowState,
        observation: ResolvedFocusedActivation,
        requestDisposition: ActivationRequestDisposition
    ) -> Bool {
        let facts = observation.facts
        let source = facts.source
        let origin = facts.origin
        if shouldSuppressObservedManagedActivation(
            entry: entry,
            requestDisposition: requestDisposition,
            source: source,
            origin: origin,
            observationGeneration: facts.observationGeneration
        ) {
            if case let .conflictsWithPendingRequest(request) = requestDisposition {
                continueManagedFocusRequest(
                    request,
                    source: source,
                    origin: origin,
                    reason: .pendingFocusMismatch
                )
            }
            return true
        }

        return false
    }

    private func acceptsTrackedActivationRequest(
        _ observation: ResolvedFocusedActivation,
        requestDisposition: ActivationRequestDisposition,
        isWorkspaceActive: Bool
    ) -> Bool {
        let facts = observation.facts
        let source = facts.source
        let origin = facts.origin
        let token = observation.token
        switch requestDisposition {
        case .matchesActiveRequest:
            break
        case let .conflictsWithPendingRequest(request):
            if shouldHonorObservedFocusOverPendingRequest(
                observedToken: token,
                source: source,
                origin: origin
            ) {
                clearManagedFocusState(
                    matching: request.token,
                    workspaceId: request.workspaceId
                )
                break
            }
            continueManagedFocusRequest(
                request,
                source: source,
                origin: origin,
                reason: .pendingFocusMismatch
            )
            return false
        case .unrelatedNoRequest:
            guard shouldHandleObservedManagedActivationWithoutPendingRequest(
                source: source,
                origin: origin,
                isWorkspaceActive: isWorkspaceActive
            ) else { return false }
        }

        return true
    }

    private func deferExternalFocusForCloseRecovery(
        _ observation: ResolvedFocusedActivation,
        requestDisposition: ActivationRequestDisposition
    ) -> Bool {
        let facts = observation.facts
        let source = facts.source
        let origin = facts.origin
        let token = observation.token
        if shouldSuppressExternalFocusFallbackDuringWindowCloseRecovery(
            observedToken: token,
            requestDisposition: requestDisposition,
            source: source,
            origin: origin
        ) {
            if case let .conflictsWithPendingRequest(request) = requestDisposition {
                continueManagedFocusRequest(
                    request,
                    source: source,
                    origin: origin,
                    reason: .pendingFocusUnmanagedToken
                )
            }
            return true
        }

        return false
    }

    private func acceptsExternalActivationFallback(
        _ observation: ResolvedFocusedActivation,
        requestDisposition: ActivationRequestDisposition
    ) -> Bool {
        let facts = observation.facts
        let source = facts.source
        let origin = facts.origin
        let token = observation.token
        switch requestDisposition {
        case let .matchesActiveRequest(request),
             let .conflictsWithPendingRequest(request):
            if shouldHonorObservedFocusOverPendingRequest(
                observedToken: token,
                source: source,
                origin: origin
            ) {
                clearManagedFocusState(
                    matching: request.token,
                    workspaceId: request.workspaceId
                )
                break
            }
            continueManagedFocusRequest(
                request,
                source: source,
                origin: origin,
                reason: .pendingFocusUnmanagedToken
            )
            return false
        case .unrelatedNoRequest:
            break
        }

        return true
    }

    private func handlePendingFocusedActivation(
        _ observation: ResolvedFocusedActivation,
        reason: WindowAdmissionPendingReason,
        verifiedManagedParentToken: WindowToken?,
        controller: WMController
    ) {
        let facts = observation.facts
        let source = facts.source
        let origin = facts.origin
        let token = observation.token
        let pid = facts.pid
        let axRef = observation.focusedWindow.axRef
        let ownsProvisionalFocus = origin == .external
            || controller.workspaceManager.externalFocusToken == token
            || frontmostApplicationPIDProvider() == token.pid
        if ownsProvisionalFocus {
            let provisionalTarget: WindowToken? = reason.hasVerifiedExternalWindowIdentity ? token : nil
            _ = controller.workspaceManager.recordExternalFocus(
                pid: pid,
                windowId: provisionalTarget?.windowId,
                verifiedManagedParentToken: provisionalTarget == nil
                    ? nil
                    : verifiedManagedParentToken
            )
            controller.surfaceReconciler.noteRestackOccurred()
            recordNiriCreateFocusTrace(
                .init(kind: .provisionalExternalFocusEntered(pid: pid, source: source))
            )
        }
        _ = scheduleFocusedAdmissionReadmit(
            continuation: .init(
                token: token,
                source: source,
                observationGeneration: facts.observationGeneration,
                callbackGeneration: facts.callbackGeneration
            ),
            axRef: axRef,
            reason: reason
        )
    }

    func areActivationFactsApplicable(_ facts: ActivationFacts, controller: WMController) -> Bool {
        guard facts.appVisibilityGeneration
            == controller.workspaceManager.appVisibilityGeneration(for: facts.pid)
        else { return false }
        guard !controller.workspaceManager.isAppHidden(pid: facts.pid) else { return false }
        if let callbackGeneration = facts.callbackGeneration {
            guard AppAXContextRegistry.contexts[facts.pid]?.callbackGeneration == callbackGeneration
            else { return false }
        }
        if let issuedAtSeq = controller.intentLedger.newestFocusIntentIssuedAtSeq(),
           issuedAtSeq > facts.requestedAtSeq
        {
            return false
        }

        return true
    }
}
