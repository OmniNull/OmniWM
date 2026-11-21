// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    @discardableResult
    func handleAppActivation(
        pid: pid_t,
        source: ActivationEventSource = .workspaceDidActivateApplication,
        origin: ActivationCallOrigin = .external,
        causalObservationGeneration: UInt64? = nil,
        callbackGeneration: UInt64? = nil,
        focusedAdmissionRetryExecution: AdmissionRetryExecution? = nil
    ) -> Bool {
        guard let controller else { return false }
        guard controller.hasStartedServices else { return false }
        guard !controller.workspaceManager.isAppHidden(pid: pid) else { return false }
        guard acceptsActivationObservation(
            pid: pid,
            source: source,
            origin: origin
        ) else { return false }
        if handleAppTerminationFocusActivation(
            pid: pid,
            source: source,
            origin: origin,
            callbackGeneration: callbackGeneration
        ) {
            return false
        }
        if retireStaleActivationObservation(pid: pid, causalObservationGeneration: causalObservationGeneration) {
            return false
        }
        guard controller.focusPolicyEngine.evaluate(
            .managedAppActivation(source: source)
        ).allowsFocusChange else {
            return false
        }
        let observationGeneration = beginActivationObservation(
            pid: pid, source: source, causalGeneration: causalObservationGeneration, controller: controller
        )

        guard prepareNativeAppSwitch(pid: pid, source: source, controller: controller) else { return false }

        let focusedToken = recordProvisionalAppActivation(
            pid: pid,
            source: source,
            origin: origin,
            controller: controller
        )

        let focusCausality = sameAppFocusCausality(
            pid: pid,
            source: source,
            origin: origin,
            focusedToken: focusedToken
        )
        return controller.factResolver.resolveActivationFacts(
            pid: pid,
            source: source,
            origin: origin,
            observationGeneration: observationGeneration,
            sameAppFocusCausality: focusCausality,
            callbackGeneration: callbackGeneration,
            appVisibilityGeneration: controller.workspaceManager.appVisibilityGeneration(for: pid),
            focusedAdmissionRetryExecution: focusedAdmissionRetryExecution
        )
    }

    private func prepareNativeAppSwitch(pid: pid_t, source: ActivationEventSource, controller: WMController) -> Bool {
        if source != .focusedWindowChanged {
            controller.focusPolicyEngine.beginLease(
                owner: .nativeAppSwitch,
                reason: source.rawValue,
                suppressesFocusFollowsMouse: true,
                duration: 0.4
            )
        }

        if pid == getpid(),
           controller.shellAppWindowManager.isManagedOwnedFocusTarget(
               activeRequest: controller.intentLedger.activeManagedRequest
           )
        {
            return false
        }

        if pid == getpid(), controller.hasFrontmostOwnedWindow || controller.hasVisibleOwnedWindow {
            if let activeRequest = controller.intentLedger.activeManagedRequest, activeRequest.token.pid == pid {
                _ = controller.cancelManagedFocusRequest(activeRequest)
            }
            _ = controller.workspaceManager.recordOwnedSurfaceFocus()
            return false
        }

        return true
    }

    private func recordProvisionalAppActivation(
        pid: pid_t,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        controller: WMController
    ) -> WindowToken? {
        let activeRequest = controller.intentLedger.activeManagedRequest
        let focusedToken = controller.workspaceManager.selectedManagedToken
        if origin == .external,
           source != .focusedWindowChanged,
           activeRequest.map({ !managedWindowToken($0.token, matchesObservedPid: pid) }) ?? true,
           activeRequest != nil || focusedToken.map({ !managedWindowToken($0, matchesObservedPid: pid) }) ?? true
        {
            if let activeRequest {
                clearManagedFocusState(
                    matching: activeRequest.token,
                    workspaceId: activeRequest.workspaceId
                )
            }
            _ = controller.workspaceManager.recordExternalFocus(pid: pid, windowId: nil)
            controller.surfaceReconciler.noteRestackOccurred()
            recordNiriCreateFocusTrace(
                .init(kind: .provisionalExternalFocusEntered(pid: pid, source: source))
            )
        }

        return focusedToken
    }

    func handleMissingFocusedWindow(
        pid: pid_t,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        requestDisposition: ActivationRequestDisposition
    ) {
        guard let controller else { return }
        if let activeRequest = controller.intentLedger.activeManagedRequest,
           managedWindowToken(activeRequest.token, matchesObservedPid: pid)
        {
            guard origin == .retry else { return }
            continueManagedFocusRequest(
                activeRequest,
                source: source,
                origin: origin,
                reason: .missingFocusedWindow
            )
            return
        }
        if let focusedToken = controller.workspaceManager.selectedManagedToken,
           managedWindowToken(focusedToken, matchesObservedPid: pid)
        {
            requestTargetedFullRescan(for: [focusedToken.pid])
            if focusedToken.pid == pid {
                _ = controller.workspaceManager.recordExternalFocus(pid: pid, windowId: nil)
                controller.surfaceReconciler.noteRestackOccurred()
            }
            return
        }

        guard shouldEnterMissingWindowFallback(requestDisposition, source: source, origin: origin) else { return }

        _ = controller.workspaceManager.recordExternalFocus(pid: pid, windowId: nil)
        recordNiriCreateFocusTrace(
            .init(
                kind: .externalFocusFallbackEntered(
                    pid: pid,
                    source: source
                )
            )
        )
    }

    private func shouldEnterMissingWindowFallback(
        _ requestDisposition: ActivationRequestDisposition, source: ActivationEventSource, origin: ActivationCallOrigin
    ) -> Bool {
        switch requestDisposition {
        case let .matchesActiveRequest(request),
             let .conflictsWithPendingRequest(request):
            if shouldHonorObservedFocusOverPendingRequest(
                observedToken: nil,
                source: source,
                origin: origin
            ) {
                clearManagedFocusState(
                    matching: request.token,
                    workspaceId: request.workspaceId
                )
                return true
            }
            guard origin == .retry else { return false }
            continueManagedFocusRequest(
                request,
                source: source,
                origin: origin,
                reason: .missingFocusedWindow
            )
            return false
        case .unrelatedNoRequest:
            return true
        }
    }

    func activationRequestDisposition(
        for pid: pid_t,
        token: WindowToken?,
        activeRequest: ManagedFocusRequest?
    ) -> ActivationRequestDisposition {
        guard let activeRequest else { return .unrelatedNoRequest }
        if let token {
            return activeRequest.token == token
                ? .matchesActiveRequest(activeRequest)
                : .conflictsWithPendingRequest(activeRequest)
        }
        return managedWindowToken(activeRequest.token, matchesObservedPid: pid)
            ? .matchesActiveRequest(activeRequest)
            : .conflictsWithPendingRequest(activeRequest)
    }

    func shouldHandleObservedManagedActivationWithoutPendingRequest(
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        isWorkspaceActive: Bool
    ) -> Bool {
        guard !isWorkspaceActive else { return true }

        switch source {
        case .focusedWindowChanged:
            return true
        case .workspaceDidActivateApplication,
             .workspaceDidUnhideApplication,
             .cgsFrontAppChanged:
            return origin == .external || origin == .appTerminationProbe
        }
    }

    func shouldHonorObservedFocusOverPendingRequest(
        observedToken: WindowToken?,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        guard source.isAuthoritative, origin == .external else { return false }
        guard let controller, let observedToken else { return true }
        switch controller.intentLedger.classifyFocusObservation(token: observedToken) {
        case .echoOf,
             .lateEcho:
            return false
        case .external:
            return true
        }
    }

    func continueManagedFocusRequest(
        _ request: ManagedFocusRequest,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        reason: ActivationRetryReason
    ) {
        guard let controller else { return }
        guard controller.intentLedger.activeManagedRequest(
            requestId: request.requestId
        )?.phase == .awaitingConfirmation else {
            return
        }
        if let updatedRequest = controller.intentLedger.recordRetry(
            requestId: request.requestId,
            source: source,
            retryLimit: Self.activationRetryLimit
        ) {
            recordNiriCreateFocusTrace(
                .init(
                    kind: .activationDeferred(
                        requestId: updatedRequest.requestId,
                        token: updatedRequest.token,
                        source: source,
                        reason: reason,
                        attempt: updatedRequest.retryCount
                    )
                )
            )
            return
        }
        guard origin != .probe else {
            return
        }
        handleActivationRetryExhausted(
            request: request,
            source: source,
            origin: origin
        )
    }

    private func handleActivationRetryExhausted(
        request: ManagedFocusRequest,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) {
        guard let controller else { return }

        requestTargetedFullRescan(for: [request.token.pid])

        _ = controller.intentLedger.cancelManagedRequest(requestId: request.requestId)
        _ = controller.workspaceManager.cancelManagedFocusRequest(
            matching: request.token,
            workspaceId: request.workspaceId,
            requestId: request.requestId
        )
        controller.scratchpadStacking.advanceScratchpadStackingAfterFocusRetryExhaustion(request)

        if let token = controller.workspaceManager.renderableFocusToken {
            controller.surfaceReconciler.noteRestackOccurred()
            recordNiriCreateFocusTrace(
                .init(
                    kind: .borderReapplied(
                        token: token,
                        phase: .retryExhaustedFallback
                    )
                )
            )
        } else {
            recordNiriCreateFocusTrace(
                .init(
                    kind: .externalFocusFallbackEntered(
                        pid: request.token.pid,
                        source: source
                    )
                )
            )
        }
    }

    func probeUnresolvedNativeFocus(after token: WindowToken) {
        guard let controller, controller.hasStartedServices,
              !controller.workspaceManager.isWindowSuppressedByMacOS(token),
              let identity = controller.workspaceManager.externalFocusIdentity,
              let pid = identity.pid,
              identity.windowId == nil,
              controller.intentLedger.activeManagedRequest == nil,
              controller.workspaceManager.pendingFocusedToken == nil,
              managedWindowTokenUsingCachedIdentity(token, matchesObservedPid: pid),
              let frontmostPID = frontmostApplicationPIDProvider(),
              managedWindowTokenUsingCachedIdentity(token, matchesObservedPid: frontmostPID)
        else { return }

        continueNativeFocusProbe(pid: pid)
    }
}
