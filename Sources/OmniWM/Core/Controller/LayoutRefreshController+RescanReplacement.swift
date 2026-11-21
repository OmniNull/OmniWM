// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension LayoutRefreshController {
    func fullRescanStructuralMatch(
        _ window: FullRescanEvaluatedWindow,
        trackedMode: TrackedWindowMode,
        context: FullRescanMutationContext
    ) -> AXEventHandler.StructuralReplacementMatch? {
        let controller = context.controller
        let enumerationSnapshot = context.enumerationSnapshot
        let token = window.identity.token
        let bundleId = window.identity.bundleId
        let evaluation = window.decision.evaluation
        return !window.identity.isTracked
            ? controller.axEventHandler.structuralReplacementMatch(
                token: token,
                candidate: .init(
                    bundleId: bundleId ?? evaluation.facts.ax
                        .bundleId,
                    mode: trackedMode,
                    facts: evaluation.facts
                ),
                capturedInventory: .init(
                    infoByWindowId: enumerationSnapshot
                        .windowServerInfoByWindowId,
                    authoritativeWindowIds: enumerationSnapshot
                        .exactWindowIds,
                    authoritativePIDs: enumerationSnapshot
                        .authoritativeTargetPIDs
                )
            )
            : nil
    }

    func rekeyFullRescanReplacement(
        _ window: FullRescanEvaluatedWindow,
        admitted: WindowAdmission,
        match structuralMatch: AXEventHandler.StructuralReplacementMatch?,
        context: FullRescanMutationContext,
        progress: inout FullRescanProgress
    ) -> Bool {
        let controller = context.controller
        let candidate = window.candidate
        let ax = window.candidate.axRef
        let winId = window.identity.token.windowId
        let token = window.identity.token
        let bundleId = window.identity.bundleId
        let appFullscreen = window.decision.appFullscreen
        let evaluation = window.decision.evaluation
        if !window.identity.isTracked,
           let windowId = UInt32(exactly: winId),
           let structuralMatch,
           controller.axEventHandler.rekeyStructuralManagedReplacement(
               match: structuralMatch,
               identity: .init(token: token, axRef: ax),
               windowId: windowId,
               candidate: .init(
                   bundleId: bundleId ?? evaluation.facts.ax
                       .bundleId,
                   mode: admitted.mode,
                   facts: evaluation.facts
               ),
               readOnlyAdmissionFrame: admitted.readOnlyFrame,
               admissionHints: evaluation.decision
                   .admissionHints,
               sizeConstraints: candidate.enumeratedWindow
                   .decisionEvidence.sizeConstraints
           )
        {
            if let minimized = candidate.minimizedAttribute {
                controller.axEventHandler.updateWindowMinimizedState(
                    minimized,
                    token: token,
                    requestRefresh: false
                )
            }
            restoreNativeFullscreenAfterStructuralReplacement(
                from: structuralMatch.token,
                to: token,
                appFullscreen: appFullscreen
            )
            progress.seenKeys.insert(token)
            progress.seenKeys.insert(structuralMatch.token)
            progress.affectedWorkspaceIds.insert(structuralMatch.workspaceId)
            return true
        }

        return false
    }

    func fullRescanDefaultWorkspace(
        _ window: FullRescanEvaluatedWindow,
        trackedMode: TrackedWindowMode,
        structuralMatch: AXEventHandler.StructuralReplacementMatch?,
        context: FullRescanMutationContext
    ) -> WorkspaceDescriptor.ID {
        let controller = context.controller
        let focusedWorkspaceId = context.focusedWorkspaceId
        let candidate = window.candidate
        let existingEntry = window.identity.existingEntry
        let evaluation = window.decision.evaluation
        let createPlacementContext = window.decision.createPlacementContext
        let placementOrigin = window.decision.placementOrigin
        return controller.resolvedWorkspaceId(
            for: evaluation,
            axRef: nil,
            existingEntry: existingEntry,
            structuralReplacementWorkspaceId: structuralMatch?.workspaceId,
            placementMode: trackedMode,
            placementContext: WorkspacePlacementContext(
                origin: placementOrigin,
                createPlacementContext: createPlacementContext,
                fallbackWorkspaceId: focusedWorkspaceId,
                reevaluation: .automatic
            ),
            appKitFrame: candidate.capturedAppKitFrame
        )
    }
}
