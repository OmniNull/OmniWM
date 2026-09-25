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
            releaseScratchpadWindow(token, entry: entry)
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
    func unassignScratchpadWindows(_ tokens: [WindowToken], on monitorId: Monitor.ID?) -> ExternalCommandResult {
        let entries = tokens.compactMap { token in
            canUnassignScratchpadWindow(token) ? workspaceManager.entry(for: token) : nil
        }
        guard !entries.isEmpty else { return .notFound }
        let hidden = entries.filter { workspaceManager.hiddenState(for: $0.token)?.isScratchpad == true }
        for entry in entries where workspaceManager.hiddenState(for: entry.token)?.isScratchpad != true {
            releaseScratchpadWindow(entry.token, entry: entry)
        }
        guard !hidden.isEmpty else { return .executed }
        return revealAndReleaseScratchpadWindows(hidden, on: monitorId) || hidden.count < entries.count
            ? .executed
            : .notFound
    }

    func canUnassignScratchpadWindow(_ token: WindowToken) -> Bool {
        workspaceManager.scratchpadIndex(for: token) != nil
            && !isManagedWindowSuspendedForNativeFullscreen(token)
            && !workspaceManager.isWindowSuppressedByMacOS(token)
            && (workspaceManager.hiddenState(for: token)?.isScratchpad == true
                || !workspaceManager.isHiddenInCorner(token))
    }

    private func revealAndReleaseScratchpadWindows(_ entries: [WindowState], on monitorId: Monitor.ID?) -> Bool {
        guard let index = entries.first.flatMap({ workspaceManager.scratchpadIndex(for: $0.token) }),
              let target = scratchpadTarget(on: monitorId)
        else {
            return false
        }
        for entry in entries where entry.workspaceId != target.workspaceId {
            reassignManagedWindow(entry.token, to: target.workspaceId)
        }
        let handles = entries.compactMap { workspaceManager.handle(for: $0.token) }
        let groupId = layoutRefreshController.revealGroups.begin(index: index) { [weak self] outcome in
            guard let self else { return }
            for handle in outcome.revealedHandles where handles.contains(where: { $0 === handle }) {
                guard let entry = workspaceManager.entry(for: handle),
                      workspaceManager.scratchpadIndex(for: handle.id) == index,
                      workspaceManager.hiddenState(for: handle.id) == nil
                else {
                    continue
                }
                releaseScratchpadWindow(handle.id, entry: entry)
            }
        }
        var revealed = false
        for entry in entries where showScratchpadWindow(
            entry,
            on: target.workspaceId,
            monitor: target.monitor,
            revealGroupId: groupId
        ) {
            revealed = true
        }
        guard revealed else {
            layoutRefreshController.revealGroups.discard(groupId)
            return false
        }
        layoutRefreshController.revealGroups.seal(groupId)
        return true
    }

    private func releaseScratchpadWindow(_ token: WindowToken, entry: WindowState) {
        cleanupScratchpadWindowResources(for: token)
        applyManagedWindowOverride(.forceTile, for: token, entry: entry)
    }

    @discardableResult
    func toggleScratchpad(
        _ index: ScratchpadIndex,
        on monitorId: Monitor.ID? = nil,
        focusOrigin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) -> ExternalCommandResult {
        guard let target = scratchpadTarget(on: monitorId) else {
            return .notFound
        }
        let members = scratchpadEntries(in: index)
        guard !members.isEmpty else { return .notFound }

        let regroupsRevealedScratchpad = workspaceManager.revealedScratchpadIndex() == index
        if regroupsRevealedScratchpad {
            if members.allSatisfy({ $0.workspaceId == target.workspaceId }) {
                cancelScratchpadReveals(for: members)
                hideScratchpadMembers(members, fallbackMonitor: target.monitor, focusOrigin: focusOrigin)
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
            hideRevealedScratchpad(revealed, fallbackMonitor: target.monitor, focusOrigin: focusOrigin)
        }

        let revealedBeforeAttempt = workspaceManager.revealedScratchpadIndex()
        workspaceManager.setRevealedScratchpad(index)
        guard revealScratchpadMembers(
            entries,
            in: index,
            on: target.workspaceId,
            monitor: target.monitor,
            focusOrigin: focusOrigin
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
        on monitorId: Monitor.ID?,
        focusOrigin: ManagedFocusOrigin = .keyboardOrProgrammatic
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
                focusWindow(token, origin: focusOrigin)
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
            hideRevealedScratchpad(revealed, fallbackMonitor: target.monitor, focusOrigin: focusOrigin)
        }
        let revealedBeforeAttempt = workspaceManager.revealedScratchpadIndex()
        workspaceManager.setRevealedScratchpad(index)
        guard revealScratchpadMembers(
            entries,
            in: index,
            on: target.workspaceId,
            monitor: target.monitor,
            preferring: token,
            focusOrigin: focusOrigin
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
