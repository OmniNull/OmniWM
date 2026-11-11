// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    private struct LiveCreatePlacement {
        let origin: WorkspacePlacementOrigin
        let capturedContext: WindowCreatePlacementContext?
    }

    private struct ClassifiedCreateFacts {
        let identity: AXManagedWindowIdentity
        let axPid: pid_t?
        let bundleId: String?
        let windowInfo: WindowServerInfo?
        let evaluation: WMController.WindowDecisionEvaluation
    }

    func prepareCreateCandidate(
        windowId: UInt32,
        windowInfo: WindowServerInfo?,
        fallbackToken: WindowToken? = nil,
        fallbackAXRef: AXWindowRef? = nil,
        allowsTrackedIdentityReplacement: Bool = false,
        placementOrigin: WorkspacePlacementOrigin = .liveCreate,
        createPlacementContext: WindowCreatePlacementContext? = nil
    ) -> CreatePreparationOutcome {
        guard let controller else {
            return .ignored(token: fallbackToken, reason: .invalidIdentity)
        }
        let ownedWindow = controller.isOwnedWindow(windowNumber: Int(windowId))
        let windowInfoToken = windowInfo?.token(matching: windowId)
        let token = fallbackToken ?? windowInfoToken
        guard let token,
              token.windowId == Int(windowId)
        else {
            return windowInfo == nil
                ? .pending(token: fallbackToken, axRef: fallbackAXRef, reason: .windowInfoMissing)
                : .ignored(token: fallbackToken, reason: .invalidIdentity)
        }
        if ownedWindow {
            discardCreatePlacementContext(windowId: windowId)
            return .ignored(token: token, reason: .ownedWindow)
        }
        guard let axRef = fallbackAXRef?.windowId == Int(windowId)
            ? fallbackAXRef
            : resolveAXWindowRef(windowId: windowId, pid: token.pid)
        else {
            return .pending(token: token, axRef: nil, reason: .axWindowMissing)
        }
        if let existingEntry = controller.workspaceManager.entry(forWindowId: Int(windowId)) {
            return prepareExistingCreateIdentity(
                existingEntry: existingEntry, identity: .init(token: token, axRef: axRef),
                windowInfoToken: windowInfoToken, allowsTrackedIdentityReplacement: allowsTrackedIdentityReplacement
            )
        }
        return prepareUntrackedCreate(
            identity: .init(token: token, axRef: axRef), windowInfo: windowInfo,
            placement: .init(origin: placementOrigin, capturedContext: createPlacementContext), controller: controller
        )
    }

    private func prepareUntrackedCreate(
        identity: AXManagedWindowIdentity, windowInfo: WindowServerInfo?,
        placement: LiveCreatePlacement, controller: WMController
    ) -> CreatePreparationOutcome {
        let token = identity.token
        let axRef = identity.axRef
        let windowId = UInt32(token.windowId)
        let axPid = AXWindowService.processIdentifier(axRef)
        recordCreatePIDMismatch(axPid, token: token, windowId: windowId)
        if isAdmissionQuarantined(windowId: Int(windowId), axRef: axRef) {
            return .ignored(token: token, reason: .quarantined)
        }

        let app = NSRunningApplication(processIdentifier: token.pid)
        let bundleId = resolveBundleId(token.pid) ?? app?.bundleIdentifier
        let matchingWindowInfo = WMController.exactWindowServerInfo(windowInfo, for: token)
        let evaluation = controller.evaluateWindowDisposition(
            axRef: axRef,
            pid: token.pid,
            windowInfo: matchingWindowInfo,
            windowServerLookupAttempted: true
        )
        let facts = ClassifiedCreateFacts(
            identity: identity, axPid: axPid, bundleId: bundleId,
            windowInfo: matchingWindowInfo, evaluation: evaluation
        )
        traceCreateClassification(facts, controller: controller)

        guard let decidedMode = evaluation.decision.trackedMode else {
            if evaluation.decision.disposition == .undecided {
                return .pending(
                    token: token,
                    axRef: axRef,
                    reason: evaluation.decision.admissionPendingReason
                )
            }
            return .ignored(token: token, reason: evaluation.decision.admissionRejectionReason)
        }
        let scratchpadAdmission = controller.scratchpadAdmission(for: evaluation, requestedMode: decidedMode)
        guard let admission = controller.resolveWindowAdmission(
            evaluation: evaluation,
            axRef: axRef,
            requestedMode: scratchpadAdmission == nil ? decidedMode : .floating
        ) else {
            return .pending(token: token, axRef: axRef, reason: .degenerateGeometry)
        }
        return prepareClassifiedCreate(
            facts, admission: admission, scratchpadAdmission: scratchpadAdmission,
            placement: placement, controller: controller
        )
    }

    func preparedCreateCandidate(
        from outcome: CreatePreparationOutcome,
        windowId: UInt32,
        trigger: AdmissionRetryTrigger
    ) -> PreparedCreate? {
        switch outcome {
        case let .prepared(candidate):
            return candidate
        case .alreadyTracked:
            noteManagedWindowSubscriptionIdentityChanged()
            discardCreatePlacementContext(windowId: windowId)
            finishAdmissionRetryAfterTracking(windowId: windowId)
        case .identityRebindPending:
            break
        case let .pending(token, axRef, reason):
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionPending,
                    pid: token?.pid,
                    windowId: Int(windowId),
                    bundleId: token.flatMap { resolveBundleId($0.pid) },
                    reason: reason.rawValue,
                    axRef: axRef
                )
            )
            _ = scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: token,
                axRef: axRef,
                reason: reason,
                trigger: trigger
            )
        case let .ignored(token, reason):
            rejectPreparedCreate(windowId: windowId, token: token, reason: reason)
        }
        return nil
    }

    private func prepareExistingCreateIdentity(
        existingEntry: WindowState, identity: AXManagedWindowIdentity,
        windowInfoToken: WindowToken?, allowsTrackedIdentityReplacement: Bool
    ) -> CreatePreparationOutcome {
        let token = identity.token
        let axRef = identity.axRef
        let windowId = UInt32(token.windowId)
        guard let existingAXRef = existingEntry.axRef else {
            return .ignored(token: token, reason: .invalidIdentity)
        }
        if CFEqual(existingAXRef.element, axRef.element), existingEntry.token == token {
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionAlreadyTracked,
                    pid: existingEntry.pid,
                    windowId: existingEntry.windowId,
                    bundleId: resolveBundleId(existingEntry.pid),
                    axRef: axRef
                )
            )
            return .alreadyTracked(existingEntry.token)
        }
        guard allowsTrackedIdentityReplacement,
              windowInfoToken == token
        else {
            return .ignored(token: token, reason: .invalidIdentity)
        }
        let rebindResult = rekeyManagedWindowIdentity(
            from: existingEntry.token,
            to: token,
            windowId: windowId,
            axRef: axRef
        )
        switch rebindResult {
        case let .committed(rekeyedEntry):
            return .alreadyTracked(rekeyedEntry.token)
        case .pending:
            return .identityRebindPending
        case .rejected:
            return .ignored(token: token, reason: .invalidIdentity)
        }
    }

    private func recordCreatePIDMismatch(_ axPid: pid_t?, token: WindowToken, windowId: UInt32) {
        if let axPid, axPid != token.pid {
            DiagnosticsEventRecorder.shared.recordLifecycle(
                name: "admissionAX.pidMismatch.expected=\(token.pid)",
                pid: axPid,
                windowId: windowId
            )
        }
    }

    private func traceCreateClassification(_ facts: ClassifiedCreateFacts, controller: WMController) {
        let token = facts.identity.token
        let axRef = facts.identity.axRef
        let axPid = facts.axPid
        let bundleId = facts.bundleId
        let evaluation = facts.evaluation
        WindowAdmissionTrace.record(
            .init(
                action: .classificationObserved,
                pid: token.pid,
                windowId: token.windowId,
                bundleId: bundleId ?? evaluation.facts.ax.bundleId,
                axPid: axPid,
                observation: WindowClassificationObservation(
                    token: token,
                    bundleId: bundleId,
                    rulesRevision: controller.settings.appRulesRevision,
                    evaluation: evaluation
                ),
                classificationRulesSnapshot: controller.settings.appRulesDiagnosticSnapshot,
                axRef: axRef
            )
        )
    }

    private func prepareClassifiedCreate(
        _ facts: ClassifiedCreateFacts, admission: WindowAdmission, scratchpadAdmission: ScratchpadAdmission?,
        placement: LiveCreatePlacement, controller: WMController
    ) -> CreatePreparationOutcome {
        let token = facts.identity.token
        let axRef = facts.identity.axRef
        let windowId = UInt32(token.windowId)
        let axPid = facts.axPid
        let bundleId = facts.bundleId
        let evaluation = facts.evaluation
        let trackedMode = scratchpadAdmission?.replacementMode(for: admission) ?? admission.mode
        let resolvedBundleId = bundleId ?? evaluation.facts.ax.bundleId
        let replacementMatch = structuralReplacementMatch(
            token: token,
            candidate: .init(bundleId: resolvedBundleId, mode: trackedMode, facts: evaluation.facts)
        )
        let workspaceId = resolveClassifiedCreatePlacement(
            facts, admission: admission, placement: placement, replacementMatch: replacementMatch,
            controller: controller
        )

        let prepared = PreparedCreate(
            windowId: windowId,
            token: token,
            axRef: axRef,
            ruleEffects: evaluation.decision.ruleEffects,
            admissionHints: evaluation.decision.admissionHints,
            appFullscreen: evaluation.appFullscreen,
            isMinimized: AXWindowService.isMinimized(axRef) ?? false,
            replacementMetadata: makeManagedReplacementMetadata(
                bundleId: resolvedBundleId,
                workspaceId: workspaceId,
                mode: trackedMode,
                facts: evaluation.facts,
                readOnlyAdmissionFrame: admission.readOnlyFrame
            ),
            structuralReplacementMatch: replacementMatch,
            observedFrame: admission.geometry?.frame,
            scratchpadAdmission: scratchpadAdmission
        )
        WindowAdmissionTrace.record(
            .init(
                action: .admissionPrepared,
                pid: token.pid,
                windowId: token.windowId,
                bundleId: resolvedBundleId,
                axPid: axPid,
                outcome: String(describing: trackedMode),
                axRef: axRef
            )
        )
        retainPreparedWindowSubscription(windowId)
        return .prepared(prepared)
    }

    private func resolveClassifiedCreatePlacement(
        _ facts: ClassifiedCreateFacts, admission: WindowAdmission,
        placement: LiveCreatePlacement, replacementMatch: StructuralReplacementMatch?, controller: WMController
    ) -> WorkspaceDescriptor.ID {
        let token = facts.identity.token
        let axRef = facts.identity.axRef
        let evaluation = facts.evaluation
        let trackedMode = admission.mode
        let inheritTrackedParentWorkspace = controller.shouldInheritTrackedParentWorkspace(for: evaluation)
        let placementFrame = WindowAdmissionGeometryEvidence.usableAppKitFrame(
            fromWindowServer: evaluation.facts.windowServer?.frame ?? facts.windowInfo?.frame
        )
        let resolvedPlacement = controller.resolveWorkspaceForNewWindow(
            workspaceName: evaluation.decision.workspaceName,
            axRef: axRef,
            pid: token.pid,
            parentWindowId: evaluation.facts.windowServer?.parentId,
            inheritTrackedParentWorkspace: inheritTrackedParentWorkspace,
            structuralReplacementWorkspaceId: replacementMatch?.workspaceId,
            placementMode: trackedMode,
            allowsFloatingSpawnPlacement: controller.allowsFloatingSpawnPlacement(
                for: evaluation,
                mode: trackedMode
            ),
            placementOrigin: placement.origin,
            createPlacementContext: placement.capturedContext,
            appKitFrame: placementFrame,
            fallbackWorkspaceId: controller.activeWorkspace()?.id
        )
        let workspaceId = resolvedPlacement.workspaceId
        recordCreatePlacementTrace(
            token: token,
            placement: resolvedPlacement,
            createPlacementContext: placement.capturedContext,
            appKitFrame: placementFrame,
            controller: controller
        )

        return workspaceId
    }

    private func rejectPreparedCreate(
        windowId: UInt32, token: WindowToken?, reason: WindowAdmissionRejectionReason
    ) {
        WindowAdmissionTrace.record(
            .init(
                action: .admissionIgnored,
                pid: token?.pid,
                windowId: Int(windowId),
                bundleId: token.flatMap { resolveBundleId($0.pid) },
                reason: reason.rawValue
            )
        )
        cancelCreatedWindowRetry(windowId: windowId)
        discardCreatePlacementContext(windowId: windowId)
        rejectDeferredReplacement(windowId: windowId)
        recordNiriCreateFocusTrace(
            .init(
                kind: .admissionRejected(
                    windowId: windowId,
                    pid: token?.pid,
                    reason: reason
                )
            )
        )
    }
}
