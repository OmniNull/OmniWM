// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    @discardableResult
    func assignFocusedWindowToScratchpad(_ index: ScratchpadIndex) -> ExternalCommandResult {
        guard let token = focusedManagedTokenForCommand() else { return .notFound }
        return assignWindowToScratchpad(token, to: index, preferredMonitor: monitorForInteraction())
    }

    @discardableResult
    func assignWindowToScratchpad(
        _ token: WindowToken,
        to index: ScratchpadIndex,
        preferredMonitor: Monitor?,
        focusOrigin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) -> ExternalCommandResult {
        guard let entry = workspaceManager.entry(for: token),
              !isManagedWindowSuspendedForNativeFullscreen(token)
        else {
            return .notFound
        }

        if workspaceManager.scratchpadIndex(for: token) == index {
            guard !workspaceManager.isHiddenInCorner(token) else {
                return .notFound
            }
            cleanupScratchpadWindowResources(for: token)
            applyManagedWindowOverride(.forceTile, for: token, entry: entry)
            return .executed
        }

        let preferredMonitor = preferredMonitor ?? workspaceManager.monitor(for: entry.workspaceId)
        let transitionedFromTiling = entry.mode == .tiling
        guard prepareWindowForScratchpadAssignment(token, preferredMonitor: preferredMonitor) else {
            return .notFound
        }

        if workspaceManager.setScratchpadMembership(token, to: index) {
            requestWorkspaceBarRefresh()
        }

        guard let updatedEntry = workspaceManager.entry(for: token),
              let hideMonitor = workspaceManager.monitor(for: updatedEntry.workspaceId) ?? preferredMonitor
        else {
            cleanupScratchpadWindowResources(for: token)
            return .notFound
        }

        if workspaceManager.revealedScratchpadIndex() != index {
            hideScratchpadMembers(
                [updatedEntry],
                fallbackMonitor: hideMonitor,
                captureGeometry: false,
                focusOrigin: focusOrigin
            )
        }

        if transitionedFromTiling {
            layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [workspaceManager.workspace(for: token) ?? updatedEntry.workspaceId]
            )
        }

        return .executed
    }

    @discardableResult
    func toggleScratchpad(_ index: ScratchpadIndex, on monitorId: Monitor.ID? = nil) -> ExternalCommandResult {
        guard let target = scratchpadTarget(on: monitorId) else {
            return .notFound
        }
        let members = scratchpadEntries(in: index)
        guard !members.isEmpty else { return .notFound }

        let regroupsRevealedScratchpad = workspaceManager.revealedScratchpadIndex() == index
        if regroupsRevealedScratchpad {
            if members.allSatisfy({ $0.workspaceId == target.workspaceId }) {
                cancelScratchpadReveals(for: members)
                hideScratchpadMembers(members, fallbackMonitor: target.monitor)
                workspaceManager.setRevealedScratchpad(nil)
                return .executed
            }
        }

        let entries = members.filter { entry in
            !isManagedWindowSuspendedForNativeFullscreen(entry.token)
                && !workspaceManager.isWindowSuppressedByMacOS(entry.token)
        }
        guard !entries.isEmpty else { return .notFound }

        if regroupsRevealedScratchpad {
            cancelScratchpadReveals(for: members)
        }

        if let revealed = workspaceManager.revealedScratchpadIndex(), revealed != index {
            layoutRefreshController.revealGroups.discardAll()
            hideRevealedScratchpad(revealed, fallbackMonitor: target.monitor)
        }

        let revealedBeforeAttempt = workspaceManager.revealedScratchpadIndex()
        workspaceManager.setRevealedScratchpad(index)
        guard revealScratchpadMembers(
            entries,
            in: index,
            on: target.workspaceId,
            monitor: target.monitor
        ) else {
            if workspaceManager.revealedScratchpadIndex() == index {
                workspaceManager.setRevealedScratchpad(revealedBeforeAttempt)
            }
            return .notFound
        }
        return .executed
    }

    @discardableResult
    func revealScratchpadWindow(
        _ token: WindowToken,
        index: ScratchpadIndex,
        on monitorId: Monitor.ID?
    ) -> ExternalCommandResult {
        guard workspaceManager.scratchpadIndex(for: token) == index,
              workspaceManager.entry(for: token) != nil,
              let target = scratchpadTarget(on: monitorId)
        else {
            return .notFound
        }

        if workspaceManager.revealedScratchpadIndex() == index,
           workspaceManager.hiddenState(for: token) == nil
        {
            if let entry = workspaceManager.entry(for: token) {
                performWindowOrdering(windowId: entry.windowId)
                focusWindow(token)
                return .executed
            }
            return .notFound
        }

        let entries = revealableScratchpadEntries(in: index)
        guard entries.contains(where: { $0.token == token }) else { return .notFound }
        if workspaceManager.revealedScratchpadIndex() == index {
            layoutRefreshController.revealGroups.discardAll()
            if entries.contains(where: { $0.workspaceId != target.workspaceId }) {
                for entry in scratchpadEntries(in: index) {
                    layoutRefreshController.cancelPendingScratchpadReveal(for: entry.token)
                }
            }
        }
        if let revealed = workspaceManager.revealedScratchpadIndex(), revealed != index {
            layoutRefreshController.revealGroups.discardAll()
            hideRevealedScratchpad(revealed, fallbackMonitor: target.monitor)
        }
        let revealedBeforeAttempt = workspaceManager.revealedScratchpadIndex()
        workspaceManager.setRevealedScratchpad(index)
        guard revealScratchpadMembers(
            entries,
            in: index,
            on: target.workspaceId,
            monitor: target.monitor,
            preferring: token
        ) else {
            if workspaceManager.revealedScratchpadIndex() == index {
                workspaceManager.setRevealedScratchpad(revealedBeforeAttempt)
            }
            return .notFound
        }
        return .executed
    }

    func reconcileScratchpadMembersAfterAppUnhide(pid: pid_t) {
        for entry in workspaceManager.entries(forPid: pid) {
            guard let index = workspaceManager.scratchpadIndex(for: entry.token),
                  workspaceManager.hiddenState(for: entry.token)?.isScratchpad == true,
                  !isManagedWindowSuspendedForNativeFullscreen(entry.token),
                  let monitor = workspaceManager.monitor(for: entry.workspaceId) ?? monitorForInteraction()
            else {
                continue
            }
            if workspaceManager.revealedScratchpadIndex() == index {
                _ = showScratchpadWindow(entry, on: entry.workspaceId, monitor: monitor)
            } else {
                _ = parkScratchpadWindow(entry, monitor: monitor)
            }
        }
    }

    @discardableResult
    func reconcileScratchpadMemberAfterNativeFullscreenExit(_ token: WindowToken) -> Bool {
        guard let entry = workspaceManager.entry(for: token),
              entry.layoutReason == .standard,
              let index = workspaceManager.scratchpadIndex(for: token),
              workspaceManager.hiddenState(for: token)?.isScratchpad == true,
              let monitor = workspaceManager.monitor(for: entry.workspaceId) ?? monitorForInteraction()
        else {
            return false
        }
        if workspaceManager.revealedScratchpadIndex() == index {
            _ = showScratchpadWindow(entry, on: entry.workspaceId, monitor: monitor)
            return false
        }
        _ = parkScratchpadWindow(entry, monitor: monitor)
        return true
    }

    private func cancelScratchpadReveals(for entries: [WindowState]) {
        layoutRefreshController.revealGroups.discardAll()
        for entry in entries {
            layoutRefreshController.cancelPendingScratchpadReveal(for: entry.token)
        }
    }
}
