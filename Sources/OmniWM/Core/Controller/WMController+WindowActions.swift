// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func closeFocusedWindow() -> ExternalCommandResult {
        guard let token = focusedManagedTokenForCommand(),
              let handle = workspaceManager.handle(for: token)
        else { return .notFound }
        return windowActionHandler.closeWindow(handle: handle) ? .executed : .windowActionFailed
    }

    func toggleFocusedWindowFloating() -> ExternalCommandResult {
        guard let token = focusedManagedTokenForCommand() else { return .notFound }
        return toggleWindowFloating(token)
    }

    @discardableResult
    func toggleWindowFloating(
        _ token: WindowToken,
        preferredMonitor: Monitor? = nil,
        arrivesQuietly: Bool = false
    ) -> ExternalCommandResult {
        guard let entry = workspaceManager.entry(for: token) else { return .notFound }
        guard entry.target.hostedMetadata?.role.parent == nil else { return .attachedWindow }

        let nextOverride: ManualWindowOverride?
        if workspaceManager.manualLayoutOverride(for: token) != nil {
            nextOverride = nil
        } else {
            nextOverride = entry.mode == .tiling ? .forceFloat : .forceTile
        }

        applyManagedWindowOverride(
            nextOverride,
            for: token,
            entry: entry,
            preferredMonitor: preferredMonitor,
            arrivesQuietly: arrivesQuietly
        )
        return .executed
    }

    func applyManagedWindowOverride(
        _ override: ManualWindowOverride?,
        for token: WindowToken,
        entry: WindowState,
        preferredMonitor: Monitor? = nil,
        arrivesQuietly: Bool = false
    ) {
        guard entry.target.hostedMetadata?.role.parent == nil else { return }
        workspaceManager.setManualLayoutOverride(override, for: token)
        let entry = workspaceManager.entry(for: token) ?? entry
        guard let axRef = entry.axRef else {
            applyHostedWindowOverride(override, entry: entry, preferredMonitor: preferredMonitor)
            return
        }
        let evaluation = evaluateWindowDisposition(
            axRef: axRef,
            pid: token.pid
        )
        guard let requestedMode = trackedModeForLifecycle(
            decision: evaluation.decision,
            existingEntry: entry
        ) else {
            workspaceManager.quietArrivalTokens.remove(token)
            axEventHandler.cancelTrackedTilingPromotionRetry(windowId: token.windowId)
            axEventHandler.retireManagedWindowAfterDecisionRejection(entry)
            return
        }
        let admission = resolveWindowAdmission(
            evaluation: evaluation,
            axRef: axRef,
            requestedMode: requestedMode,
            existingMode: entry.mode
        )
        let isNiriWorkspace = workspaceManager.activeLayoutKind(for: entry.workspaceId) == .niri
        if (admission?.mode ?? requestedMode) == .tiling, arrivesQuietly, entry.mode != .tiling, isNiriWorkspace {
            workspaceManager.quietArrivalTokens.insert(token)
        } else {
            workspaceManager.quietArrivalTokens.remove(token)
        }
        guard let admission else {
            axEventHandler.scheduleTrackedTilingPromotionRetry(token: token, axRef: axRef, reason: .degenerateGeometry)
            return
        }

        _ = transitionWindowMode(
            for: token,
            to: admission.mode,
            preferredMonitor: preferredMonitor ?? monitorForInteraction(),
            applyFloatingFrame: true,
            observedFrame: admission.geometry?.frame
        )
        finishWindowOverrideTracking(token)
        layoutRefreshController.requestRelayout(
            reason: .windowRuleReevaluation,
            affectedWorkspaceIds: [entry.workspaceId],
            suppressWindowActivation: arrivesQuietly && !isNiriWorkspace
        )
    }

    private func finishWindowOverrideTracking(_ token: WindowToken) {
        if let windowId = UInt32(exactly: token.windowId) {
            axEventHandler.finishAdmissionRetryAfterTracking(windowId: windowId)
        }
    }

    private func applyHostedWindowOverride(
        _ override: ManualWindowOverride?,
        entry: WindowState,
        preferredMonitor: Monitor?
    ) {
        _ = transitionWindowMode(
            for: entry.token,
            to: override == .forceFloat ? .floating : .tiling,
            preferredMonitor: preferredMonitor ?? monitorForInteraction(),
            applyFloatingFrame: true
        )
        layoutRefreshController.requestRelayout(
            reason: .windowRuleReevaluation,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    func raiseAllFloatingWindows() {
        windowActionHandler.raiseAllFloatingWindows()
    }

    func toggleFloatingFocus() -> ExternalCommandResult {
        windowActionHandler.toggleFloatingFocus()
    }

    @discardableResult
    func restoreVisibleWorkspaceInactiveFloatingWindows() -> Int {
        layoutRefreshController.restoreWorkspaceInactiveFloatingWindows(
            activeWorkspaceIds: workspaceManager.visibleWorkspaceIds()
        )
    }

    func hasVisibleWorkspaceInactiveFloatingWindows() -> Bool {
        layoutRefreshController.hasWorkspaceInactiveFloatingWindows(
            activeWorkspaceIds: workspaceManager.visibleWorkspaceIds()
        )
    }

    @discardableResult
    func rescueOffscreenWindows() -> Int {
        guard !isLockScreenActive else { return 0 }

        let candidates = floatingRescueCandidates()
        let rescuePlan = RestorePlanner().planFloatingRescue(candidates)
        var frameUpdates: [AXFrameApplicationTarget] = []
        var visibleJobs: [(pid: pid_t, windowId: Int)] = []
        var rescuedEntries: [WindowState] = []

        for operation in rescuePlan.operations {
            guard let entry = workspaceManager.entry(for: operation.token) else { continue }
            let wasWorkspaceInactiveHidden = workspaceManager.hiddenState(for: operation.token)?
                .workspaceInactive == true
            if !wasWorkspaceInactiveHidden {
                workspaceManager.updateFloatingGeometry(
                    frame: operation.targetFrame,
                    for: operation.token,
                    referenceMonitor: operation.targetMonitor,
                    restoreToFloating: true
                )
            }
            guard let axRef = entry.axRef else {
                workspaceManager.setHiddenState(nil, for: operation.token)
                _ = shellAppWindowManager.setFrame(operation.targetFrame, for: operation.token)
                _ = shellAppWindowManager.orderFront(operation.token)
                continue
            }
            if wasWorkspaceInactiveHidden {
                workspaceManager.setHiddenState(nil, for: operation.token)
                visibleJobs.append((operation.pid, operation.windowId))
                axManager.markWindowActive(operation.windowId)
            }
            axManager.forceApplyNextFrame(for: operation.windowId)
            frameUpdates.append(
                .init(pid: entry.pid, window: axRef, frame: operation.targetFrame)
            )
            rescuedEntries.append(entry)
        }

        if !frameUpdates.isEmpty {
            if !visibleJobs.isEmpty {
                axManager.unsuppressFrameWrites(visibleJobs)
            }
            axManager.applyFramesParallel(frameUpdates)
            for entry in rescuedEntries {
                if let axRef = entry.axRef {
                    windowFocusOperations.raiseWindow(axRef.element)
                }
            }
        }

        return rescuePlan.rescuedCount
    }

    private func floatingRescueCandidates() -> [RestorePlanner.FloatingRescueCandidate] {
        var candidates: [RestorePlanner.FloatingRescueCandidate] = []
        let visibleWorkspaceIds = workspaceManager.visibleWorkspaceIds()

        for entry in workspaceManager.allFloatingEntries() {
            guard entry.layoutReason == .standard else { continue }
            guard !workspaceManager.isWindowSuppressedByMacOS(entry.token) else { continue }
            guard visibleWorkspaceIds.contains(entry.workspaceId) else { continue }
            guard let targetMonitor = workspaceManager.monitor(for: entry.workspaceId)
                ?? monitorForInteraction()
                ?? workspaceManager.monitors.first
            else {
                continue
            }

            guard let targetFrame = workspaceManager.resolvedFloatingFrame(
                for: entry.token,
                preferredMonitor: targetMonitor
            ) else {
                continue
            }

            candidates.append(
                .init(
                    token: entry.token,
                    pid: entry.pid,
                    windowId: entry.windowId,
                    workspaceId: entry.workspaceId,
                    targetMonitor: targetMonitor,
                    currentFrame: liveFrame(for: entry),
                    targetFrame: targetFrame,
                    isScratchpadHidden: workspaceManager.hiddenState(for: entry.token)?.isScratchpad == true,
                    isWorkspaceInactiveHidden: workspaceManager.hiddenState(for: entry.token)?.workspaceInactive == true
                )
            )
        }

        return candidates
    }
}
