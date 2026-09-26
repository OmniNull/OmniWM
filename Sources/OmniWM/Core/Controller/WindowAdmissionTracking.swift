// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    func trackPreparedCreate(_ candidate: PreparedCreate) {
        defer { releasePreparedWindowSubscription(candidate.windowId) }
        guard let controller else { return }
        discardCreatePlacementContext(windowId: candidate.windowId)
        let axPid = AXWindowService.processIdentifier(candidate.axRef)
        recordNiriCreateFocusTrace(
            .init(
                kind: .candidateTracked(
                    token: candidate.token,
                    axPid: axPid,
                    workspaceId: candidate.workspaceId
                )
            )
        )

        guard let trackedEntry = admitPreparedCreate(candidate, axPid: axPid, controller: controller) else { return }
        let floatingTargetFrame = floatingCreateTarget(candidate, entry: trackedEntry, controller: controller)
        bindPreparedCreate(trackedEntry, floatingTargetFrame: floatingTargetFrame, controller: controller)
        controller.layoutRefreshController.requestRelayout(
            reason: .axWindowCreated,
            affectedWorkspaceIds: [trackedEntry.workspaceId],
            suppressWindowActivation: false
        )
        scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(trackedEntry.pid)])
        finishAdmissionRetryAfterTracking(windowId: candidate.windowId)
    }

    private func shouldApplyFloatingCreateFrameImmediately(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            return false
        }
        return controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == workspaceId
    }

    private func scheduleAXContextWarmup(for pid: pid_t) {
        Task { @MainActor [weak self] in
            await self?.warmAXContextIfNeeded(for: pid)
        }
    }

    private func warmAXContextIfNeeded(for pid: pid_t) async {
        guard let controller,
              controller.hasStartedServices,
              let app = NSRunningApplication(processIdentifier: pid)
        else {
            return
        }
        guard await controller.axManager.ensureContext(for: app, pid: pid),
              controller.hasStartedServices,
              !Task.isCancelled
        else { return }
        controller.axManager.bindManagedWindows(controller.workspaceManager.entries(forPid: pid))
    }

    private func scheduleFloatingCreateFrameApplication(
        _ targetFrame: CGRect,
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        let canApplySynchronously = controller.axManager.hasContext(for: token.pid)
        let plannedSeq = controller.workspaceManager.worldSeq

        if canApplySynchronously {
            applyFloatingCreateFrame(
                targetFrame,
                token: token,
                workspaceId: workspaceId,
                plannedSeq: plannedSeq
            )
            if controller.axManager.recentFrameWriteFailure(for: token.windowId) == .contextUnavailable {
                Task { @MainActor [weak self] in
                    guard let self, self.controller?.hasStartedServices == true else { return }
                    await self.warmAXContextIfNeeded(for: token.pid)
                    guard self.controller?.hasStartedServices == true else { return }
                    self.applyFloatingCreateFrame(
                        targetFrame,
                        token: token,
                        workspaceId: workspaceId,
                        plannedSeq: plannedSeq
                    )
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self, self.controller?.hasStartedServices == true else { return }
            await self.warmAXContextIfNeeded(for: token.pid)
            guard self.controller?.hasStartedServices == true else { return }
            self.applyFloatingCreateFrame(
                targetFrame,
                token: token,
                workspaceId: workspaceId,
                plannedSeq: plannedSeq
            )
            if self.controller?.axManager.recentFrameWriteFailure(for: token.windowId) == .contextUnavailable {
                await self.warmAXContextIfNeeded(for: token.pid)
                guard self.controller?.hasStartedServices == true else { return }
                self.applyFloatingCreateFrame(
                    targetFrame,
                    token: token,
                    workspaceId: workspaceId,
                    plannedSeq: plannedSeq
                )
            }
        }
    }

    private func applyFloatingCreateFrame(
        _ targetFrame: CGRect,
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        plannedSeq: UInt64
    ) {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token),
              entry.workspaceId == workspaceId,
              controller.workspaceManager.isSeqCurrent(
                  plannedSeq,
                  for: workspaceId,
                  domains: .layoutCommit
              ),
              shouldApplyFloatingCreateFrameImmediately(for: workspaceId)
        else {
            return
        }

        controller.axManager.forceApplyNextFrame(for: token.windowId)
        controller.axManager.applyFramesParallel([
            .init(pid: token.pid, window: entry.axRef, frame: targetFrame)
        ])
    }

    private func admitPreparedCreate(
        _ candidate: PreparedCreate,
        axPid: pid_t?,
        controller: WMController
    ) -> WindowState? {
        let isMinimized = controller.workspaceManager.entry(for: candidate.token)?.observedState.isMinimized
            ?? candidate.isMinimized
        if isMinimized {
            controller.axManager.setWindowMinimized(true, token: candidate.token)
        }
        let trackedToken = controller.workspaceManager.addWindow(
            candidate.axRef,
            pid: candidate.token.pid,
            windowId: candidate.token.windowId,
            to: candidate.workspaceId,
            mode: candidate.mode,
            ruleEffects: candidate.ruleEffects,
            admissionHints: candidate.admissionHints,
            lifetimeAuthority: .directLifecycle,
            allowsNativeFocusAdoption: !candidate.appFullscreen && !isMinimized,
            isMinimized: isMinimized,
            managedReplacementMetadata: candidate.replacementMetadata
        )
        guard let trackedEntry = controller.workspaceManager.entry(for: trackedToken) else {
            handleDisappearedCreate(candidate, axPid: axPid)
            return nil
        }
        guard trackedToken == candidate.token else {
            handleCollidingCreate(candidate, trackedEntry: trackedEntry, axPid: axPid)
            return nil
        }
        if trackedEntry.mode == .tiling {
            controller.dwindleLayoutHandler.markIncomingWindowForStacking(trackedToken, in: candidate.workspaceId)
        }
        WindowAdmissionTrace.record(
            .init(
                action: .admissionTracked,
                pid: trackedEntry.pid,
                windowId: trackedEntry.windowId,
                bundleId: candidate.bundleId,
                axPid: axPid,
                outcome: String(describing: trackedEntry.mode),
                axRef: trackedEntry.axRef
            )
        )

        return trackedEntry
    }

    private func floatingCreateTarget(
        _ candidate: PreparedCreate,
        entry: WindowState,
        controller: WMController
    ) -> CGRect? {
        var floatingTargetFrame: CGRect?
        if entry.mode == .floating, !entry.observedState.isMinimized {
            let observedFrame = AXWindowService.framePreferFast(candidate.axRef)
                ?? (try? AXWindowService.frame(candidate.axRef))
            let preferredMonitor = controller.workspaceManager.monitor(for: entry.workspaceId)

            if let observedFrame {
                if controller.workspaceManager.floatingState(for: entry.token) == nil {
                    controller.workspaceManager.updateFloatingGeometry(
                        frame: observedFrame,
                        for: entry.token,
                        referenceMonitor: preferredMonitor
                    )
                }
            }

            floatingTargetFrame = controller.workspaceManager.resolvedFloatingFrame(
                for: entry.token,
                preferredMonitor: preferredMonitor
            )
        }

        return floatingTargetFrame
    }

    private func bindPreparedCreate(
        _ trackedEntry: WindowState,
        floatingTargetFrame: CGRect?,
        controller: WMController
    ) {
        let liveTrackedEntry = controller.workspaceManager.entry(for: trackedEntry.token) ?? trackedEntry
        controller.axManager.bindManagedWindows(
            controller.workspaceManager.entries(forPid: liveTrackedEntry.pid)
        )
        if let floatingTargetFrame,
           shouldApplyFloatingCreateFrameImmediately(for: liveTrackedEntry.workspaceId)
        {
            scheduleFloatingCreateFrameApplication(
                floatingTargetFrame,
                token: trackedEntry.token,
                workspaceId: liveTrackedEntry.workspaceId
            )
        } else {
            scheduleAXContextWarmup(for: liveTrackedEntry.pid)
        }
    }

    private func handleDisappearedCreate(_ candidate: PreparedCreate, axPid: pid_t?) {
        WindowAdmissionTrace.record(
            .init(
                action: .admissionDisappeared,
                pid: candidate.token.pid,
                windowId: candidate.token.windowId,
                bundleId: candidate.bundleId,
                axPid: axPid,
                reason: "workspace_add_failed",
                axRef: candidate.axRef
            )
        )
        scheduleAXContextWarmup(for: candidate.token.pid)
        rejectDeferredReplacement(windowId: candidate.windowId)
    }

    private func handleCollidingCreate(_ candidate: PreparedCreate, trackedEntry: WindowState, axPid: pid_t?) {
        WindowAdmissionTrace.record(
            .init(
                action: .admissionReplaced,
                pid: trackedEntry.pid,
                windowId: trackedEntry.windowId,
                bundleId: candidate.bundleId,
                axPid: axPid,
                competingPid: candidate.token.pid,
                reason: "workspace_identity_replaced",
                axRef: trackedEntry.axRef
            )
        )
        finishAdmissionRetryAfterCollision(
            windowId: candidate.windowId,
            token: candidate.token,
            axRef: candidate.axRef
        )
    }
}
