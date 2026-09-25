// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
final class AppRevealActions {
    private weak var controller: WMController?
    private let requestApplicationUnhide: (pid_t) -> WindowActionHandler.AppUnhideRequestResult

    init(
        controller: WMController,
        requestApplicationUnhide: @escaping (pid_t) -> WindowActionHandler.AppUnhideRequestResult
    ) {
        self.controller = controller
        self.requestApplicationUnhide = requestApplicationUnhide
    }

    func requestIfNeeded(
        handle: WindowHandle,
        destination: AppRevealFocusDestination,
        focusOrigin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) -> Bool {
        let trace = AppRevealRequestTrace(handle: handle, destination: destination)

        guard let controller else {
            return trace.reject(.controllerUnavailable)
        }
        guard let currentHandle = controller.workspaceManager.handle(for: handle.id) else {
            return trace.reject(.handleMissing)
        }
        guard currentHandle === handle else {
            return trace.reject(.handleIdentityChanged)
        }
        guard let entry = controller.workspaceManager.entry(for: handle) else {
            return trace.reject(.entryMissing)
        }
        let pendingApps = pendingAppRevealApplications(
            controller: controller,
            targetPID: entry.pid,
            destination: destination
        )
        guard !pendingApps.isEmpty else {
            return performAppRevealDestination(
                destination,
                token: handle.id,
                workspaceId: entry.workspaceId,
                focusOrigin: focusOrigin,
                controller: controller
            )
        }
        guard entry.layoutReason == .standard
            || controller.isManagedWindowSuspendedForNativeFullscreen(entry.token)
        else {
            return trace.reject(
                .ineligibleLayout,
                workspaceId: entry.workspaceId,
                generation: controller.workspaceManager.appVisibilityGeneration(for: entry.pid)
            )
        }
        return requestUnhide(
            pendingApps, handle: handle, entry: entry,
            destination: destination, focusOrigin: focusOrigin
        )
    }

    private func requestUnhide(
        _ pendingApps: [pid_t: UInt64], handle: WindowHandle, entry: WindowState,
        destination: AppRevealFocusDestination, focusOrigin: ManagedFocusOrigin
    ) -> Bool {
        guard let controller else { return false }
        let intent = controller.intentLedger.beginAppRevealFocus(
            token: entry.token,
            workspaceId: entry.workspaceId,
            handleIdentity: ObjectIdentifier(handle),
            pendingApps: pendingApps,
            focusFingerprint: Self.appRevealFocusFingerprint(controller: controller),
            destination: destination,
            origin: focusOrigin
        )
        var requestFailed = false
        for pid in pendingApps.keys.sorted() {
            let unhideResult = requestApplicationUnhide(pid)
            let traceOutcome: AppVisibilityTrace.Outcome
            let traceReason: AppVisibilityTrace.Reason?
            switch unhideResult {
            case .applicationUnavailable:
                traceOutcome = .failed
                traceReason = .applicationUnavailable
                requestFailed = true
            case .requestReportedSent:
                traceOutcome = .requested
                traceReason = nil
            case .requestReportedNotSent:
                traceOutcome = .indeterminate
                traceReason = .unhideRequestReportedNotSent
            }
            AppVisibilityTrace.record(
                .reveal,
                pid: pid,
                outcome: traceOutcome,
                intentId: intent.id,
                windowId: pid == entry.pid ? entry.windowId : nil,
                workspaceId: entry.workspaceId,
                generation: pendingApps[pid],
                intentGeneration: pendingApps[pid],
                destination: destination.traceDestination,
                reason: traceReason
            )
        }
        guard !requestFailed else {
            controller.intentLedger.cancelAppRevealFocus(intentId: intent.id)
            return false
        }
        return true
    }

    @discardableResult
    func completeAppRevealFocus(intentId: IntentID) -> Bool {
        guard let controller else {
            AppVisibilityTrace.record(
                .reveal,
                outcome: .rejected,
                intentId: intentId,
                reason: .controllerUnavailable
            )
            return false
        }
        guard let intent = controller.intentLedger.openIntent(id: intentId) else {
            AppVisibilityTrace.record(
                .reveal,
                outcome: .rejected,
                intentId: intentId,
                reason: .intentMissing
            )
            return false
        }
        guard case let .appRevealFocus(payload) = intent.kind else {
            controller.intentLedger.cancelAppRevealFocus(intentId: intentId)
            AppVisibilityTrace.record(
                .reveal,
                pid: intent.kind.targetPid,
                outcome: .rejected,
                intentId: intentId,
                reason: .intentKindMismatch
            )
            return false
        }

        return AppRevealCompletion(
            controller: controller,
            actions: self,
            intentId: intentId,
            payload: payload,
            focusOrigin: intent.origin
        )
        .perform()
    }

    private func pendingAppRevealApplications(
        controller: WMController,
        targetPID: pid_t,
        destination: AppRevealFocusDestination
    ) -> [pid_t: UInt64] {
        switch destination {
        case .window:
            guard controller.workspaceManager.isAppHidden(pid: targetPID) else { return [:] }
            return [
                targetPID: controller.workspaceManager.appVisibilityGeneration(for: targetPID)
            ]
        case let .scratchpad(index, _),
             let .scratchpadWindow(index, _):
            var pendingApps: [pid_t: UInt64] = [:]
            for token in controller.workspaceManager.scratchpadMembers(in: index) {
                guard let pid = controller.workspaceManager.entry(for: token)?.pid,
                      pendingApps[pid] == nil,
                      controller.workspaceManager.isAppHidden(pid: pid)
                else {
                    continue
                }
                pendingApps[pid] = controller.workspaceManager.appVisibilityGeneration(for: pid)
            }
            return pendingApps
        }
    }

    private func performAppRevealDestination(
        _ destination: AppRevealFocusDestination,
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        focusOrigin: ManagedFocusOrigin,
        controller: WMController
    ) -> Bool {
        switch destination {
        case .window:
            controller.windowActionHandler.navigateToWindowInternal(
                token: token,
                workspaceId: workspaceId,
                focusOrigin: focusOrigin
            )
        case let .scratchpad(index, monitorId):
            controller.activateScratchpadFromBar(index: index, on: monitorId) == .executed
        case let .scratchpadWindow(index, monitorId):
            performSelectedScratchpadReveal(
                token: token,
                workspaceId: workspaceId,
                index: index,
                monitorId: monitorId,
                focusOrigin: focusOrigin
            )
        }
    }

    func performSelectedScratchpadReveal(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        index: ScratchpadIndex,
        monitorId: Monitor.ID?,
        focusOrigin: ManagedFocusOrigin
    ) -> Bool {
        guard let controller else { return false }
        guard controller.workspaceManager.scratchpadIndex(for: token) == index else {
            return controller.windowActionHandler.navigateToWindowInternal(
                token: token,
                workspaceId: workspaceId,
                focusOrigin: focusOrigin
            )
        }
        return controller.revealScratchpadWindow(
            token,
            index: index,
            on: monitorId,
            focusOrigin: focusOrigin
        ) == .executed
    }

    static func appRevealFocusFingerprint(controller: WMController) -> AppRevealFocusFingerprint {
        AppRevealFocusFingerprint(
            selectedManagedToken: controller.workspaceManager.selectedManagedToken,
            pendingFocusedToken: controller.workspaceManager.pendingFocusedToken,
            pendingFocusedWorkspaceId: controller.workspaceManager.pendingFocusedWorkspaceId,
            nativeFocusOwner: controller.workspaceManager.nativeFocusOwner,
            interactionMonitorId: controller.workspaceManager.interactionMonitorId,
            activeWorkspaceIdsByMonitor: Dictionary(
                uniqueKeysWithValues: controller.workspaceManager.monitors.compactMap { monitor in
                    controller.workspaceManager.activeWorkspace(on: monitor.id).map {
                        (monitor.id, $0.id)
                    }
                }
            )
        )
    }

    static func suspendedNativeFullscreenOriginalToken(
        for currentToken: WindowToken,
        controller: WMController
    ) -> WindowToken? {
        guard controller.workspaceManager.showsNativeFullscreenPlaceholder(for: currentToken),
              let record = controller.workspaceManager.nativeFullscreenRecord(for: currentToken),
              record.transition == .suspended
        else {
            return nil
        }
        return record.originalToken
    }
}
