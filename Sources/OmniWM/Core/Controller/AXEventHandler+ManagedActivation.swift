// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    private struct ManagedActivationRequest {
        let source: ActivationEventSource
        let confirmRequest: Bool?
        let origin: ActivationCallOrigin
        let activeRequestId: UInt64?
        let bindCurrentPidRequest: Bool
        let callbackGeneration: UInt64?
    }

    private struct ManagedActivationObservation {
        let entry: WindowState
        let isWorkspaceActive: Bool
        let monitorId: Monitor.ID?
        let shouldActivateWorkspace: Bool
        let isRetriedAuthoritativeSystemModalFocus: Bool
        let activeRequest: ManagedFocusRequest?
        let shouldConfirmRequest: Bool
        let source: ActivationEventSource
        let focusObservation: EchoClassification
        let omitsExplicitOrdering: Bool
    }

    func handleManagedAppActivation(
        entry: WindowState,
        isWorkspaceActive: Bool,
        appFullscreen: Bool,
        source: ActivationEventSource = .focusedWindowChanged,
        confirmRequest: Bool? = nil,
        origin: ActivationCallOrigin = .external,
        activeRequestId: UInt64? = nil,
        bindCurrentPidRequest: Bool = true,
        callbackGeneration: UInt64? = nil
    ) {
        guard let controller else { return }
        let request = ManagedActivationRequest(
            source: source,
            confirmRequest: confirmRequest,
            origin: origin,
            activeRequestId: activeRequestId,
            bindCurrentPidRequest: bindCurrentPidRequest,
            callbackGeneration: callbackGeneration
        )
        guard let observation = prepareManagedActivation(
            entry: entry,
            isWorkspaceActive: isWorkspaceActive,
            appFullscreen: appFullscreen,
            request: request,
            controller: controller
        ) else { return }
        var confirmedManagedRequest: ManagedFocusRequest?
        guard applyManagedActivationFocus(
            observation,
            controller: controller,
            confirmedRequest: &confirmedManagedRequest
        ) else { return }

        applyManagedActivationOrdering(observation, controller: controller)
        let preferredMouseFrame = activateManagedLayoutTarget(observation, controller: controller)
        finishManagedActivation(
            observation,
            controller: controller,
            preferredMouseFrame: preferredMouseFrame,
            confirmedRequest: confirmedManagedRequest
        )
    }

    private func prepareManagedActivation(
        entry: WindowState,
        isWorkspaceActive: Bool,
        appFullscreen: Bool,
        request: ManagedActivationRequest,
        controller: WMController
    ) -> ManagedActivationObservation? {
        WindowAdmissionTrace.record(
            .init(
                action: .managedFocusObserved,
                pid: entry.pid,
                windowId: entry.windowId,
                bundleId: entry.managedReplacementMetadata?.bundleId,
                reason: String(describing: request.source),
                callbackGeneration: request.callbackGeneration,
                axRef: entry.axRef
            )
        )
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
        return observeManagedActivation(
            entry: controller.workspaceManager.entry(for: entry.token) ?? entry,
            isWorkspaceActive: isWorkspaceActive,
            request: request,
            controller: controller
        )
    }

    private func observeManagedActivation(
        entry: WindowState,
        isWorkspaceActive: Bool,
        request: ManagedActivationRequest,
        controller: WMController
    ) -> ManagedActivationObservation {
        let monitorId = controller.workspaceManager.monitorId(for: entry.workspaceId)
        let shouldActivateWorkspace = !isWorkspaceActive && !controller.isTransferringWindow
        let isRetriedAuthoritativeSystemModalFocus = request.source.isAuthoritative
            && request.origin == .retry
            && controller.workspaceManager.systemModalFocusToken == entry.token
        let activeRequest: ManagedFocusRequest?
        if let activeRequestId = request.activeRequestId {
            activeRequest = controller.intentLedger.activeManagedRequest(requestId: activeRequestId)
        } else if request.bindCurrentPidRequest {
            activeRequest = controller.intentLedger.activeManagedRequest(for: entry.pid)
        } else {
            activeRequest = nil
        }
        let shouldConfirmRequest = request.confirmRequest ?? true
        let focusObservation = controller.intentLedger.classifyFocusObservation(token: entry.token)
        let omitsExplicitOrdering = switch focusObservation {
        case let .echoOf(intent),
             let .lateEcho(intent):
            intent.origin == .focusFollowsMouse && !controller.settings.focus.raiseOnMouseFocus
        case .external:
            false
        }
        return ManagedActivationObservation(
            entry: entry,
            isWorkspaceActive: isWorkspaceActive,
            monitorId: monitorId,
            shouldActivateWorkspace: shouldActivateWorkspace,
            isRetriedAuthoritativeSystemModalFocus: isRetriedAuthoritativeSystemModalFocus,
            activeRequest: activeRequest,
            shouldConfirmRequest: shouldConfirmRequest,
            source: request.source,
            focusObservation: focusObservation,
            omitsExplicitOrdering: omitsExplicitOrdering
        )
    }

    private func applyManagedActivationFocus(
        _ observation: ManagedActivationObservation,
        controller: WMController,
        confirmedRequest: inout ManagedFocusRequest?
    ) -> Bool {
        let entry = observation.entry
        guard observation.shouldConfirmRequest else {
            _ = controller.workspaceManager.setManagedFocus(
                entry.token,
                in: entry.workspaceId,
                onMonitor: observation.monitorId
            )
            return true
        }
        if let request = observation.activeRequest,
           !controller.workspaceManager.pendingManagedFocusMatches(
               token: entry.token,
               workspaceId: entry.workspaceId,
               requestId: request.requestId
           )
        {
            _ = controller.cancelManagedFocusRequest(request)
            return false
        }
        let confirmationRequestId = observation.activeRequest?.requestId
        guard controller.workspaceManager.canConfirmManagedFocus(
            entry.token,
            in: entry.workspaceId,
            requestId: confirmationRequestId
        ) else { return false }
        _ = controller.workspaceManager.confirmManagedFocus(
            entry.token,
            in: entry.workspaceId,
            onMonitor: observation.monitorId,
            activateWorkspaceOnMonitor: observation.shouldActivateWorkspace,
            requestId: confirmationRequestId
        )
        confirmedRequest = confirmManagedActivationRequest(observation, controller: controller)
        recordNiriCreateFocusTrace(
            .init(kind: .focusConfirmed(
                token: entry.token,
                workspaceId: entry.workspaceId,
                source: observation.source
            ))
        )
        completeAppTerminationFocusRecoveryIfNeeded(entry.token)
        return true
    }

    private func confirmManagedActivationRequest(
        _ observation: ManagedActivationObservation,
        controller: WMController
    ) -> ManagedFocusRequest? {
        guard let activeRequest = observation.activeRequest else { return nil }
        if activeRequest.token == observation.entry.token {
            return controller.intentLedger.confirmManagedRequest(
                token: observation.entry.token,
                source: observation.source
            )
        }
        _ = controller.cancelManagedFocusRequest(activeRequest)
        return nil
    }

    private func applyManagedActivationOrdering(
        _ observation: ManagedActivationObservation,
        controller: WMController
    ) {
        if !observation.omitsExplicitOrdering,
           observation.isRetriedAuthoritativeSystemModalFocus,
           frontmostApplicationPIDProvider() == observation.entry.pid,
           controller.workspaceManager.nativeManagedFocusToken == observation.entry.token
        {
            controller.performWindowOrdering(windowId: observation.entry.windowId)
        }
    }

    private func activateManagedLayoutTarget(
        _ observation: ManagedActivationObservation,
        controller: WMController
    ) -> CGRect? {
        let entry = observation.entry
        switch controller.workspaceManager.activeLayoutKind(for: entry.workspaceId) {
        case .dwindle:
            guard let engine = controller.dwindleEngine else { return nil }
            _ = controller.dwindleLayoutHandler.activateWindow(
                entry.token,
                in: entry.workspaceId,
                layoutRefresh: observation.isWorkspaceActive,
                focusAfterLayout: false
            )
            return engine.contentFrame(for: entry.token, in: entry.workspaceId)
                ?? engine.findNode(for: entry.token, in: entry.workspaceId)?.cachedFrame
        case .niri:
            return activateManagedNiriTarget(observation, controller: controller)
        }
    }

    private func activateManagedNiriTarget(
        _ observation: ManagedActivationObservation,
        controller: WMController
    ) -> CGRect? {
        let entry = observation.entry
        let wsId = entry.workspaceId
        guard let engine = controller.niriEngine,
              let node = engine.findNode(for: entry.token, in: wsId),
              controller.workspaceManager.monitor(for: wsId) != nil
        else { return nil }
        let preferredFrame = node.renderedFrame ?? node.frame
        var state = controller.workspaceManager.niriViewportState(for: wsId)
        let preservesPointerViewport = switch observation.focusObservation {
        case let .echoOf(intent),
             let .lateEcho(intent):
            intent.origin.preservesViewportOnActivation
        case .external: false
        }
        let preserveViewport = controller.workspaceManager.animationDriver.hasMotion(in: wsId)
            || preservesPointerViewport
            || preservesAppTerminationRecoveryViewport(for: entry.token)
        let preserveReplacementViewport = isProtectedManagedReplacementFocus(
            token: entry.token,
            workspaceId: wsId
        )
        controller.niriLayoutHandler.activateNode(
            node, in: wsId, state: &state,
            options: managedActivationOptions(
                isWorkspaceActive: observation.isWorkspaceActive,
                preserveViewport: preserveViewport,
                preserveReplacementViewport: preserveReplacementViewport
            )
        )
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: wsId,
                viewportState: state,
                rememberedFocusToken: nil,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        if preserveReplacementViewport {
            completeManagedReplacementFocusTransactionIfNeeded(token: entry.token, workspaceId: wsId)
        }
        return preferredFrame
    }

    private func managedActivationOptions(
        isWorkspaceActive: Bool,
        preserveViewport: Bool,
        preserveReplacementViewport: Bool
    ) -> NodeActivationOptions {
        if preserveReplacementViewport {
            return .init(
                ensureVisible: false,
                preserveViewportAnchor: true,
                layoutRefresh: isWorkspaceActive,
                axFocus: false,
                startAnimation: false
            )
        }
        if preserveViewport {
            return .init(
                ensureVisible: false,
                preserveViewportAnchor: true,
                layoutRefresh: false,
                axFocus: false,
                startAnimation: false
            )
        }
        return .init(layoutRefresh: isWorkspaceActive, axFocus: false)
    }

    private func finishManagedActivation(
        _ observation: ManagedActivationObservation,
        controller: WMController,
        preferredMouseFrame: CGRect?,
        confirmedRequest: ManagedFocusRequest?
    ) {
        let entry = observation.entry
        controller.surfaceReconciler.noteRestackOccurred()
        if observation.shouldActivateWorkspace, observation.shouldConfirmRequest {
            controller.syncMonitorsToNiriEngine()
            controller.layoutRefreshController.commitWorkspaceTransition(reason: .appActivationTransition)
        }
        if observation.shouldConfirmRequest,
           controller.moveMouseToFocusedWindowEnabled,
           !suppressesMouseWarp(for: entry.token),
           controller.intentLedger.allowsMouseToFocusedWarp(for: entry.token),
           controller.workspaceManager.nativeManagedFocusToken == entry.token
        {
            controller.moveMouseToWindow(entry.token, preferredFrame: preferredMouseFrame)
        }
        controller.scratchpadStacking.noteScratchpadStackingAppActivation(pid: entry.pid, source: observation.source)
        if let confirmedRequest {
            controller.scratchpadStacking.continueScratchpadStacking(after: confirmedRequest)
        }
    }
}
