// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension LayoutRefreshController {
    func completeFullRescanTracking(
        _ window: FullRescanEvaluatedWindow,
        admission: FullRescanAdmission,
        admittedToken: WindowToken,
        context: FullRescanMutationContext,
        progress: inout FullRescanProgress
    ) -> Bool {
        let controller = context.controller
        let candidate = window.candidate
        let winId = window.identity.token.windowId
        let token = window.identity.token
        let shouldPreservePreFullscreenState = window.decision.shouldPreservePreFullscreenState
        let admissionHints = admission.assignment.admissionHints
        guard admittedToken == token else {
            progress.seenKeys.insert(admittedToken)
            if let admittedEntry = controller.workspaceManager.entry(for: admittedToken) {
                progress.affectedWorkspaceIds.insert(admittedEntry.workspaceId)
            }
            if let windowId = UInt32(exactly: winId) {
                controller.axEventHandler.finishAdmissionRetryAfterTracking(
                    windowId: windowId
                )
            }
            return false
        }
        controller.workspaceManager.setCachedConstraints(
            candidate.enumeratedWindow.decisionEvidence.sizeConstraints,
            for: admittedToken
        )
        if window.identity.isTracked {
            _ = controller.workspaceManager.updateAdmissionHints(admissionHints, for: admittedToken)
        } else {
            controller.axEventHandler.discardCreatePlacementContext(for: winId)
        }
        if let windowId = UInt32(exactly: winId) {
            controller.axEventHandler.finishAdmissionRetryAfterTracking(
                windowId: windowId
            )
        }

        controller.axEventHandler.applyObservedWindowOrdering(
            candidate.windowServerInfo,
            token: admittedToken,
            appFullscreen: window.decision.appFullscreen,
            requestRefresh: false
        )

        if shouldPreservePreFullscreenState {
            _ = controller.reconcileScratchpadMemberAfterNativeFullscreenExit(admittedToken)
            progress.seenKeys.insert(admittedToken)
            return false
        }

        return true
    }

    func applyFullRescanGeometry(
        _ window: FullRescanEvaluatedWindow,
        trackedMode: TrackedWindowMode,
        admission: FullRescanAdmission,
        admittedToken: WindowToken,
        context: FullRescanMutationContext
    ) {
        let controller = context.controller
        guard controller.workspaceManager.withEntry(admittedToken, { $0.observedState.isNativeSuppressed }) != true
        else {
            return
        }
        let candidate = window.candidate
        let oldMode = admission.refreshedEntry?.mode
        let wsForWindow = admission.assignment.workspaceId
        if let oldMode, oldMode != trackedMode {
            _ = controller.transitionWindowMode(
                for: admittedToken,
                to: trackedMode,
                preferredMonitor: controller.workspaceManager.monitor(for: wsForWindow),
                applyFloatingFrame: false,
                observedFrame: candidate.capturedAppKitFrame,
                allowLiveFrameFallback: false
            )
        } else if trackedMode == .floating {
            controller.seedFloatingGeometryIfNeeded(
                for: admittedToken,
                preferredMonitor: controller.workspaceManager.monitor(for: wsForWindow),
                observedFrame: candidate.capturedAppKitFrame,
                allowLiveFrameFallback: false
            )
        }
    }
}
