// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    @discardableResult
    func prepareWindowForScratchpadAssignment(
        _ token: WindowToken,
        preferredMonitor: Monitor? = nil
    ) -> Bool {
        guard let entry = workspaceManager.entry(for: token) else {
            return false
        }

        if entry.mode == .floating {
            guard captureVisibleFloatingGeometry(for: token, preferredMonitor: preferredMonitor) != nil
                || workspaceManager.floatingState(for: token) != nil
            else {
                return false
            }
            if workspaceManager.manualLayoutOverride(for: token) != .forceFloat {
                workspaceManager.setManualLayoutOverride(.forceFloat, for: token)
            }
            return true
        }

        guard let frame = liveFrame(for: entry) else { return false }
        let referenceMonitor = floatingPlacementMonitor(
            for: entry,
            preferredMonitor: preferredMonitor,
            frame: frame
        )
        _ = workspaceManager.setWindowMode(.floating, for: token)
        workspaceManager.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: referenceMonitor,
            restoreToFloating: true
        )
        if workspaceManager.manualLayoutOverride(for: token) != .forceFloat {
            workspaceManager.setManualLayoutOverride(.forceFloat, for: token)
        }
        return true
    }

    func scratchpadTarget(
        on monitorId: Monitor.ID? = nil
    ) -> (workspaceId: WorkspaceDescriptor.ID, monitor: Monitor)? {
        guard let monitor = monitorId.flatMap({ workspaceManager.monitor(byId: $0) }) ?? monitorForInteraction(),
              let workspaceId = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
        else {
            return nil
        }
        return (workspaceId, monitor)
    }

    private func visibleFocusRecoveryToken(
        in workspaceId: WorkspaceDescriptor.ID,
        excluding excludedTokens: Set<WindowToken>
    ) -> WindowToken? {
        let explicitCandidates = [
            workspaceManager.lastFocusedToken(in: workspaceId),
            workspaceManager.preferredFocusToken(in: workspaceId),
            workspaceManager.lastFloatingFocusedToken(in: workspaceId),
            workspaceManager.selectedManagedToken
        ]

        for candidate in explicitCandidates {
            guard let candidate,
                  !excludedTokens.contains(candidate),
                  let entry = workspaceManager.entry(for: candidate),
                  entry.workspaceId == workspaceId,
                  isManagedWindowDisplayable(entry.token)
            else {
                continue
            }
            return candidate
        }

        if let tiledEntry = workspaceManager.tiledEntries(in: workspaceId).first(where: {
            !excludedTokens.contains($0.token) && isManagedWindowDisplayable($0.token)
        }) {
            return tiledEntry.token
        }

        return workspaceManager.floatingEntries(in: workspaceId).first(where: {
            !excludedTokens.contains($0.token) && isManagedWindowDisplayable($0.token)
        })?.token
    }

    func recoverFocusAfterScratchpadHide(
        in workspaceId: WorkspaceDescriptor.ID,
        excluding tokens: Set<WindowToken>,
        on monitorId: Monitor.ID?,
        focusOrigin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) {
        if let nextFocusToken = visibleFocusRecoveryToken(in: workspaceId, excluding: tokens) {
            focusWindow(nextFocusToken, origin: focusOrigin)
            return
        }

        _ = workspaceManager.resolveAndSetWorkspaceFocusToken(in: workspaceId, onMonitor: monitorId)
    }

    func cleanupScratchpadWindowResources(for token: WindowToken) {
        layoutRefreshController.cancelPendingScratchpadReveal(for: token)
        let frameEntry = [(pid: token.pid, windowId: token.windowId)]
        axManager.cancelPendingFrameJobs(frameEntry, reason: "scratchpad-cleanup")
        axManager.unsuppressFrameWrites(frameEntry)
        AXWindowService.unpinAXElement(for: UInt32(token.windowId))
        if workspaceManager.clearScratchpadIfMatches(token) {
            requestWorkspaceBarRefresh()
        }
    }

    func rekeyScratchpadWindowResources(from oldToken: WindowToken, to newToken: WindowToken, axRef: AXWindowRef) {
        guard workspaceManager.hiddenState(for: newToken)?.isScratchpad == true else { return }
        AXWindowService.unpinAXElement(for: UInt32(oldToken.windowId))
        AXWindowService.pinAXElement(axRef.element, for: UInt32(newToken.windowId))
    }
}
