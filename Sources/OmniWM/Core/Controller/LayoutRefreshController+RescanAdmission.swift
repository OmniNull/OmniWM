// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension LayoutRefreshController {
    func fullRescanAdmissionAssignment(
        _ window: FullRescanEvaluatedWindow,
        defaultWorkspace: WorkspaceDescriptor.ID,
        context: FullRescanMutationContext
    ) -> FullRescanAdmissionAssignment {
        let controller = context.controller
        let pid = window.identity.token.pid
        let winId = window.identity.token.windowId
        let existingEntry = window.identity.existingEntry
        let appFullscreen = window.decision.appFullscreen
        let decision = window.decision.evaluation.decision
        let deferredTrackedEntry = window.decision.deferredTrackedEntry
        let shouldPreservePreFullscreenState = window.decision.shouldPreservePreFullscreenState
        if let existingEntry {
            if shouldPreservePreFullscreenState {
                controller.workspaceManager.restoreNativeFullscreenRecord(for: existingEntry.token)
                markNativeFullscreenRestoredForFrameApply(existingEntry.token)
                let restoredEntry = controller.workspaceManager.entry(for: existingEntry.token) ?? existingEntry
                return .init(
                    workspaceId: restoredEntry.workspaceId,
                    ruleEffects: restoredEntry.ruleEffects,
                    admissionHints: restoredEntry.admissionHints
                )
            } else if appFullscreen {
                cancelPendingScratchpadReveal(for: existingEntry.token)
                _ = controller.workspaceManager.markNativeFullscreenSuspended(
                    existingEntry.token,
                    ownsNativeFocus: false
                )
                let existingAssignment = controller.workspaceAssignment(pid: pid, windowId: winId)
                return .init(
                    workspaceId: deferredTrackedEntry?.workspaceId ?? existingAssignment ?? defaultWorkspace,
                    ruleEffects: deferredTrackedEntry?.ruleEffects ?? decision.ruleEffects,
                    admissionHints: deferredTrackedEntry?.admissionHints ?? decision.admissionHints
                )
            } else if let deferredTrackedEntry {
                return .init(
                    workspaceId: deferredTrackedEntry.workspaceId,
                    ruleEffects: deferredTrackedEntry.ruleEffects,
                    admissionHints: deferredTrackedEntry.admissionHints
                )
            }
        }
        let existingAssignment = controller.workspaceAssignment(pid: pid, windowId: winId)
        return .init(
            workspaceId: existingAssignment ?? defaultWorkspace,
            ruleEffects: decision.ruleEffects,
            admissionHints: decision.admissionHints
        )
    }

    func prepareFullRescanAdmission(
        _ window: FullRescanEvaluatedWindow,
        trackedMode: TrackedWindowMode,
        assignment: FullRescanAdmissionAssignment,
        context: FullRescanMutationContext
    ) -> FullRescanAdmission {
        let controller = context.controller
        let existingEntry = window.identity.existingEntry
        let refreshedEntry = existingEntry
            .flatMap { controller.workspaceManager.entry(for: $0.token) }
            ?? existingEntry
        let admittedMode = refreshedEntry?.mode ?? trackedMode
        let managedReplacementMetadata = fullRescanReplacementMetadata(
            window,
            refreshedEntry: refreshedEntry,
            assignment: assignment,
            admittedMode: admittedMode
        )
        return FullRescanAdmission(
            assignment: assignment,
            refreshedEntry: refreshedEntry,
            admittedMode: admittedMode,
            managedReplacementMetadata: managedReplacementMetadata
        )
    }

    private func fullRescanReplacementMetadata(
        _ window: FullRescanEvaluatedWindow,
        refreshedEntry: WindowState?,
        assignment: FullRescanAdmissionAssignment,
        admittedMode: TrackedWindowMode
    ) -> ManagedReplacementMetadata {
        let bundleId = window.identity.bundleId
        let evaluation = window.decision.evaluation
        let wsForWindow = assignment.workspaceId
        let parentWindowId = if let windowServer = evaluation.facts.windowServer {
            windowServer.parentId == 0 ? nil : windowServer.parentId
        } else {
            refreshedEntry?.managedReplacementMetadata?.parentWindowId
        }
        return ManagedReplacementMetadata(
            bundleId: evaluation.facts.ax.bundleId ?? bundleId ?? refreshedEntry?.managedReplacementMetadata?
                .bundleId,
            workspaceId: wsForWindow,
            mode: admittedMode,
            role: evaluation.facts.ax.role ?? refreshedEntry?.managedReplacementMetadata?.role,
            subrole: evaluation.facts.ax.subrole ?? refreshedEntry?.managedReplacementMetadata?.subrole,
            title: evaluation.facts.ax.title ?? refreshedEntry?.managedReplacementMetadata?.title,
            windowLevel: evaluation.facts.windowServer?.level ?? refreshedEntry?.managedReplacementMetadata?
                .windowLevel,
            parentWindowId: parentWindowId,
            frame: evaluation.facts.windowServer?.frame ?? refreshedEntry?.managedReplacementMetadata?.frame,
            transientWindowServerEvidence: refreshedEntry?.managedReplacementMetadata?
                .transientWindowServerEvidence == true
                || evaluation.facts.windowServer?.hasTransientSurfaceEvidence == true,
            degradedWindowServerChildEvidence: refreshedEntry?.managedReplacementMetadata?
                .degradedWindowServerChildEvidence == true
                || evaluation.facts.degradedWindowServerChildEvidence
        )
    }

    func admitFullRescanWindow(
        _ window: FullRescanEvaluatedWindow,
        admission: FullRescanAdmission,
        context: FullRescanMutationContext
    ) -> WindowToken {
        let controller = context.controller
        let ax = window.candidate.axRef
        let pid = window.identity.token.pid
        let winId = window.identity.token.windowId
        let appFullscreen = window.decision.appFullscreen
        let shouldPreservePreFullscreenState = window.decision.shouldPreservePreFullscreenState
        let refreshedEntry = admission.refreshedEntry
        let admittedMode = admission.admittedMode
        let managedReplacementMetadata = admission.managedReplacementMetadata
        let wsForWindow = admission.assignment.workspaceId
        let ruleEffects = admission.assignment.ruleEffects
        let admissionHints = admission.assignment.admissionHints
        let isMinimized = refreshedEntry?.observedState.isMinimized ?? window.candidate.minimizedAttribute ?? false
        if let refreshedEntry,
           !Self.shouldReadmitTrackedWindow(
               entry: refreshedEntry,
               target: .init(
                   workspaceId: wsForWindow,
                   mode: admittedMode,
                   ruleEffects: ruleEffects
               ),
               shouldPreservePreFullscreenState: shouldPreservePreFullscreenState,
               appFullscreen: appFullscreen
           )
        {
            _ = controller.workspaceManager.setManagedReplacementMetadata(
                managedReplacementMetadata,
                for: refreshedEntry.token
            )
            return refreshedEntry.token
        } else {
            if isMinimized {
                controller.axManager.setWindowMinimized(true, token: window.identity.token)
            }
            if refreshedEntry == nil, admittedMode == .tiling {
                controller.dwindleLayoutHandler.markIncomingWindowForStacking(window.identity.token, in: wsForWindow)
            }
            return controller.workspaceManager.addWindow(
                ax,
                pid: pid,
                windowId: winId,
                to: wsForWindow,
                mode: admittedMode,
                ruleEffects: ruleEffects,
                admissionHints: admissionHints,
                allowsNativeFocusAdoption: !appFullscreen && !isMinimized,
                isMinimized: isMinimized,
                managedReplacementMetadata: managedReplacementMetadata
            )
        }
    }
}
