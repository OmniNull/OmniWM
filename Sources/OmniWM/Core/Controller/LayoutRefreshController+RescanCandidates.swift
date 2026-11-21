// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension LayoutRefreshController {
    func reconcileFullRescanCandidate(
        _ candidate: FullRescanWindowCandidate,
        context: FullRescanMutationContext,
        progress: inout FullRescanProgress
    ) {
        guard let identity = prepareFullRescanCandidateIdentity(candidate, context: context, progress: &progress)
        else { return }
        let decision = prepareFullRescanWindowDecision(candidate, identity: identity, context: context)
        let window = FullRescanEvaluatedWindow(candidate: candidate, identity: identity, decision: decision)
        let scratchpadAdmission = identity.isTracked
            ? nil
            : decision.effectiveTrackedMode.flatMap {
                context.controller.scratchpadAdmission(for: decision.evaluation, requestedMode: $0)
            }
        let requestedMode = scratchpadAdmission == nil ? decision.effectiveTrackedMode : .floating
        let admitted = requestedMode.flatMap { mode in
            if decision.shouldPreservePreFullscreenState { return WindowAdmission(mode: mode) }
            return context.controller.resolveWindowAdmission(
                evaluation: decision.evaluation,
                axRef: candidate.axRef,
                requestedMode: mode,
                existingMode: identity.existingEntry?.mode
            )
        }
        if shouldYieldFullRescanWindow(
            window, trackedMode: admitted?.mode ?? requestedMode, context: context, progress: &progress
        ) { return }
        if let admitted {
            reconcileTrackedFullRescanWindow(
                window,
                admitted: admitted,
                scratchpadAdmission: scratchpadAdmission,
                context: context,
                progress: &progress
            )
        } else if requestedMode == nil {
            rejectFullRescanWindow(window, context: context, progress: &progress)
        } else {
            context.controller.axEventHandler.scheduleGeometryAdmissionRetry(
                token: identity.token, axRef: candidate.axRef,
                existingEntry: identity.existingEntry, placementOrigin: decision.placementOrigin
            )
            if let existingEntry = identity.existingEntry {
                progress.seenKeys.insert(existingEntry.token)
            }
        }
    }

    private func reconcileTrackedFullRescanWindow(
        _ window: FullRescanEvaluatedWindow,
        admitted: WindowAdmission,
        scratchpadAdmission: ScratchpadAdmission?,
        context: FullRescanMutationContext,
        progress: inout FullRescanProgress
    ) {
        let trackedMode = admitted.mode
        let replacementAdmission = scratchpadAdmission.map {
            WindowAdmission(mode: $0.replacementMode(for: admitted), geometry: admitted.geometry)
        } ?? admitted
        let structuralMatch = fullRescanStructuralMatch(
            window,
            trackedMode: replacementAdmission.mode,
            context: context
        )
        if rekeyFullRescanReplacement(
            window, admitted: replacementAdmission, match: structuralMatch, context: context, progress: &progress
        ) { return }
        let defaultWorkspace = fullRescanDefaultWorkspace(
            window,
            trackedMode: trackedMode,
            structuralMatch: structuralMatch,
            context: context
        )
        let assignment = fullRescanAdmissionAssignment(window, defaultWorkspace: defaultWorkspace, context: context)
        progress.affectedWorkspaceIds.insert(assignment.workspaceId)
        let admission = prepareFullRescanAdmission(
            window,
            trackedMode: trackedMode,
            assignment: assignment,
            context: context
        )
        let arrival = fullRescanScratchpadArrival(window, scratchpadAdmission: scratchpadAdmission, context: context)
        let admittedToken = admitFullRescanWindow(window, admission: admission, context: context)
        guard completeFullRescanTracking(
            window,
            admission: admission,
            admittedToken: admittedToken,
            context: context,
            progress: &progress
        ) else { return }
        applyFullRescanGeometry(
            window,
            trackedMode: trackedMode,
            admission: admission,
            admittedToken: admittedToken,
            context: context
        )
        joinFullRescanScratchpad(
            scratchpadAdmission, window: window, admitted: admitted,
            admittedToken: admittedToken, arrival: arrival
        )
        progress.seenKeys.insert(admittedToken)
    }

    private func fullRescanScratchpadArrival(
        _ window: FullRescanEvaluatedWindow,
        scratchpadAdmission: ScratchpadAdmission?,
        context: FullRescanMutationContext
    ) -> ScratchpadJoinArrival? {
        guard let scratchpadAdmission else { return nil }
        let controller = context.controller
        guard window.decision.createPlacementContext != nil else {
            return .quiet(previousFocusToken: controller.workspaceManager.selectedManagedToken)
        }
        return controller.axEventHandler.scratchpadJoinArrival(
            window.identity.token,
            in: scratchpadAdmission.index,
            canCountAsFocused: !window.decision.appFullscreen && window.candidate.minimizedAttribute != true
        )
    }

    private func joinFullRescanScratchpad(
        _ scratchpadAdmission: ScratchpadAdmission?,
        window: FullRescanEvaluatedWindow,
        admitted: WindowAdmission,
        admittedToken: WindowToken,
        arrival: ScratchpadJoinArrival?
    ) {
        guard let scratchpadAdmission, let arrival, let controller else { return }
        controller.joinScratchpadOnAdmission(
            admittedToken,
            scratchpadAdmission,
            observedFrame: window.candidate.capturedAppKitFrame ?? admitted.geometry?.frame,
            appFullscreen: window.decision.appFullscreen,
            arrival: arrival
        )
    }

    private func shouldYieldFullRescanWindow(
        _ window: FullRescanEvaluatedWindow,
        trackedMode: TrackedWindowMode?,
        context: FullRescanMutationContext,
        progress: inout FullRescanProgress
    ) -> Bool {
        guard !window.identity.isTracked else { return false }
        let enumerationSnapshot = context.enumerationSnapshot
        let scope = context.scope
        let token = window.identity.token
        let existingEntry = window.identity.existingEntry
        let bundleId = window.identity.bundleId
        let evaluation = window.decision.evaluation
        let decision = evaluation.decision
        return yieldToDeferredCreate(
            .init(
                token: token,
                bundleId: bundleId ?? evaluation.facts.ax.bundleId,
                mode: trackedMode,
                factsAreDeferred: decision.disposition == .undecided,
                facts: evaluation.facts,
                entry: existingEntry
            ),
            scope: scope,
            capturedInventory: .init(
                infoByWindowId: enumerationSnapshot.windowServerInfoByWindowId,
                authoritativeWindowIds: enumerationSnapshot.exactWindowIds,
                authoritativePIDs: enumerationSnapshot.authoritativeTargetPIDs
            ),
            seenKeys: &progress.seenKeys
        )
    }

    private func rejectFullRescanWindow(
        _ window: FullRescanEvaluatedWindow,
        context: FullRescanMutationContext,
        progress: inout FullRescanProgress
    ) {
        let controller = context.controller
        let ax = window.candidate.axRef
        let pid = window.identity.token.pid
        let winId = window.identity.token.windowId
        let token = window.identity.token
        let existingEntry = window.identity.existingEntry
        let decision = window.decision.evaluation.decision
        let placementOrigin = window.decision.placementOrigin
        if existingEntry != nil {
            controller.axEventHandler.cancelTrackedTilingPromotionRetry(windowId: winId)
            progress.decisionBasedRemovals.append(existingEntry?.token ?? token)
        } else {
            if decision.disposition == .undecided,
               let windowId = UInt32(exactly: winId)
            {
                let reason: WindowAdmissionPendingReason = decision.deferredReason
                    == .windowServerEvidenceMissing ? .windowServerEvidenceMissing : .factsDeferred
                _ = controller.axEventHandler.scheduleCandidateAdmissionRetry(
                    windowId: windowId,
                    pid: pid,
                    axRef: ax,
                    reason: reason,
                    placementOrigin: placementOrigin
                )
            } else {
                controller.axEventHandler.discardCreatePlacementContext(for: winId)
            }
        }
    }
}
