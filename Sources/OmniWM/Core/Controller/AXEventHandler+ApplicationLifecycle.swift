// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    func handleAppTerminated(pid: pid_t, frontmostPID: pid_t? = nil) {
        guard let controller else { return }
        let allEntries = controller.workspaceManager.allEntries()
        if !allEntries.contains(where: { $0.pid == pid }),
           let recovery = controller.intentLedger.openAppTerminationFocusRecovery()?.payload,
           recovery.departingToken.pid == pid,
           recovery.terminationHandled
        {
            return
        }
        let focusRecovery = controller.axEventHandler.beginAppTerminationFocusRecovery(
            pid: pid,
            fallbackPID: frontmostPID
        )
        controller.intentLedger.cancelAppRevealFocus(pid: pid)
        let wasHidden = controller.workspaceManager.isAppHidden(pid: pid)
        if !wasHidden {
            controller.workspaceManager.invalidateAppVisibility(for: pid, source: .service)
        }
        let dependentTargetPIDs = controller.axEventHandler.fullRescanTargetPIDsDepending(
            onTerminatedPID: pid,
            entries: allEntries
        )
        controller.axEventHandler.cleanupFocusStateForTerminatedApp(pid: pid)
        let removedEntries = allEntries.filter { $0.pid == pid }
        let scratchpadTokens = scratchpadTokens(in: removedEntries, manager: controller.workspaceManager)
        let affectedWorkspaces = controller.workspaceManager.removeWindowsForApp(pid: pid)
        if !removedEntries.isEmpty {
            controller.axEventHandler.noteManagedWindowSubscriptionIdentityChanged()
        }
        cleanupTerminatedAppWindows(
            pid: pid,
            removedEntries: removedEntries,
            scratchpadTokens: scratchpadTokens,
            wasHidden: wasHidden,
            controller: controller
        )
        validateFocusAfterAppTermination(
            affectedWorkspaces: affectedWorkspaces,
            focusRecovery: focusRecovery,
            controller: controller
        )
        invalidateTerminatedApplication(
            pid: pid,
            dependentTargetPIDs: dependentTargetPIDs,
            affectedWorkspaces: affectedWorkspaces,
            controller: controller
        )
    }

    private func invalidateTerminatedApplication(
        pid: pid_t,
        dependentTargetPIDs: Set<pid_t>,
        affectedWorkspaces: Set<WorkspaceDescriptor.ID>,
        controller: WMController
    ) {
        controller.surfaceReconciler.noteRestackOccurred()
        controller.appInfoCache.evict(pid: pid)
        if !dependentTargetPIDs.isEmpty {
            controller.layoutRefreshController.requestFullRescan(
                reason: .staleFullRescan,
                scope: .targeted(appPIDs: dependentTargetPIDs, nativeSpaceIds: [])
            )
        }
        if !affectedWorkspaces.isEmpty {
            controller.layoutRefreshController.requestRelayout(
                reason: .appTerminated,
                affectedWorkspaceIds: affectedWorkspaces
            )
        }
    }

    private func scratchpadTokens(in entries: [WindowState], manager: WorkspaceManager) -> Set<WindowToken> {
        Set(entries.compactMap { entry in
            let token = entry.token
            return manager.isScratchpadToken(token)
                || manager.hiddenState(for: token)?.isScratchpad == true
                ? token
                : nil
        })
    }

    private func cleanupTerminatedAppWindows(
        pid: pid_t,
        removedEntries: [WindowState],
        scratchpadTokens: Set<WindowToken>,
        wasHidden: Bool,
        controller: WMController
    ) {
        if wasHidden {
            controller.axManager.setMacOSAppHidden(
                false,
                pid: pid,
                entries: removedEntries.map { (pid: $0.pid, windowId: $0.windowId) }
            )
            controller.workspaceManager.setAppHidden(false, pid: pid, source: .service)
        }
        for entry in removedEntries {
            controller.mouseEventHandler.discardNativeTitleBarDrag(for: entry.token)
            controller.axManager.removeWindowState(pid: entry.pid, expectedWindow: entry.axRef)
            if scratchpadTokens.contains(entry.token) {
                controller.cleanupScratchpadWindowResources(for: entry.token)
            }
            controller.warpQuakeTerminal.noteWindowRemoved(entry.token)
        }
    }

    private func validateFocusAfterAppTermination(
        affectedWorkspaces: Set<WorkspaceDescriptor.ID>,
        focusRecovery: (workspaceId: WorkspaceDescriptor.ID, preferredToken: WindowToken)?,
        controller: WMController
    ) {
        var focusValidationWorkspaces = affectedWorkspaces
        if let focusRecovery {
            focusValidationWorkspaces.insert(focusRecovery.workspaceId)
        }
        for workspaceId in focusValidationWorkspaces {
            if let monitorId = controller.workspaceManager.monitorId(for: workspaceId),
               controller.workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId
            {
                controller.ensureFocusedTokenValid(
                    in: workspaceId,
                    preferredRecoveryToken: focusRecovery?.workspaceId == workspaceId
                        ? focusRecovery?.preferredToken
                        : nil
                )
            }
        }
    }

    func handleAppLaunched(pid: pid_t) {
        controller?.layoutRefreshController.requestFullRescan(
            reason: .appLaunched,
            scope: .targeted(appPIDs: [pid], nativeSpaceIds: [])
        )
    }

    func reconcileHiddenApplications() {
        guard let controller else { return }
        let hiddenPIDs = Set(
            NSWorkspace.shared.runningApplications.lazy
                .filter { !$0.isTerminated && $0.isHidden }
                .map(\.processIdentifier)
        )
        let previousPIDs = controller.workspaceManager.hiddenAppPIDs
        for pid in previousPIDs.subtracting(hiddenPIDs) {
            controller.axEventHandler.handleAppUnhidden(pid: pid, source: .service)
        }
        for pid in hiddenPIDs.subtracting(previousPIDs) {
            controller.axEventHandler.handleAppHidden(pid: pid, source: .service)
        }
    }
}
