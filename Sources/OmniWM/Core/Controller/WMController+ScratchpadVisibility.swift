// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    private func logicalScratchpadHiddenState(
        for entry: WindowState,
        monitor: Monitor
    ) -> HiddenState? {
        guard let floatingState = workspaceManager.floatingState(for: entry.token) else { return nil }
        let referenceMonitor = floatingState.referenceMonitorId.flatMap { workspaceManager.monitor(byId: $0) }
            ?? monitor
        return HiddenState(
            proportionalPosition: layoutRefreshController.proportionalPosition(
                topLeft: floatingState.lastFrame.topLeftCorner,
                in: referenceMonitor.frame
            ),
            referenceMonitorId: referenceMonitor.id,
            reason: .scratchpad
        )
    }

    @discardableResult
    func parkScratchpadWindow(
        _ entry: WindowState,
        monitor: Monitor,
        captureGeometry: Bool = true
    ) -> Bool {
        let logicalOnly = workspaceManager.isWindowSuppressedByMacOS(entry.token)
            || isManagedWindowSuspendedForNativeFullscreen(entry.token)
        if logicalOnly {
            guard let hiddenState = logicalScratchpadHiddenState(for: entry, monitor: monitor) else {
                return false
            }
            let frameEntry = [(entry.pid, entry.windowId)]
            axManager.cancelPendingFrameJobs(frameEntry, reason: "scratchpad-hide")
            axManager.suppressFrameWrites(frameEntry)
            workspaceManager.setHiddenState(hiddenState, for: entry.token)
            return true
        }

        if captureGeometry {
            _ = captureVisibleFloatingGeometry(for: entry.token, preferredMonitor: monitor)
        }
        if let ref = AXWindowService.axWindowRef(for: UInt32(entry.windowId), pid: entry.pid) {
            AXWindowService.pinAXElement(ref.element, for: UInt32(entry.windowId))
        }

        let parked = layoutRefreshController.hideWindow(
            entry,
            monitor: monitor,
            side: layoutRefreshController.preferredHideSide(for: monitor),
            reason: .scratchpad
        )
        if !parked,
           workspaceManager.hiddenState(for: entry.token) == nil,
           !workspaceManager.isWindowSuppressedByMacOS(entry.token),
           !isManagedWindowSuspendedForNativeFullscreen(entry.token)
        {
            axManager.unsuppressFrameWrites([(entry.pid, entry.windowId)])
        }
        return parked
    }

    func hideScratchpadMembers(
        _ entries: [WindowState],
        fallbackMonitor: Monitor,
        captureGeometry: Bool = true,
        focusOrigin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) {
        let focusedEntry = workspaceManager.selectedManagedToken.flatMap { focusedToken in
            entries.first { $0.token == focusedToken }
        }
        for entry in entries {
            _ = parkScratchpadWindow(
                entry,
                monitor: workspaceManager.monitor(for: entry.workspaceId) ?? fallbackMonitor,
                captureGeometry: captureGeometry
            )
        }
        requestWorkspaceBarRefresh()
        if let focusedEntry {
            recoverFocusAfterScratchpadHide(
                in: workspaceManager.workspace(for: focusedEntry.token) ?? focusedEntry.workspaceId,
                excluding: Set(entries.map(\.token)),
                on: (workspaceManager.monitor(for: focusedEntry.workspaceId) ?? fallbackMonitor).id,
                focusOrigin: focusOrigin
            )
        }
    }

    @discardableResult
    func showScratchpadWindow(
        _ entry: WindowState,
        on workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        onRevealed: LayoutRefreshController.PostLayoutAction? = nil,
        revealGroupId: UInt64? = nil
    ) -> Bool {
        let entry = workspaceManager.entry(for: entry.token) ?? entry
        axManager.markWindowActive(entry.windowId)

        if let hiddenState = workspaceManager.hiddenState(for: entry.token) {
            if hiddenState.isScratchpad {
                return layoutRefreshController.restoreScratchpadWindow(
                    entry,
                    monitor: monitor,
                    onSuccess: onRevealed,
                    revealGroupId: revealGroupId
                )
            }
            return layoutRefreshController.unhideWindow(
                entry,
                monitor: monitor,
                onSuccess: onRevealed,
                revealGroupId: revealGroupId
            )
        }

        if let frame = workspaceManager.resolvedFloatingFrame(
            for: entry.token,
            preferredMonitor: monitor
        ) {
            axManager.forceApplyNextFrame(for: entry.windowId)
            axManager.applyFramesParallel([
                .init(pid: entry.pid, window: entry.axRef, frame: frame)
            ])
        }

        if let revealGroupId {
            layoutRefreshController.revealGroups.recordSuccess(entry.token, groupId: revealGroupId)
        } else {
            onRevealed?()
        }
        return true
    }

    func scratchpadEntries(in index: ScratchpadIndex) -> [WindowState] {
        workspaceManager.scratchpadMembers(in: index).compactMap { token in
            guard let entry = workspaceManager.entry(for: token) else {
                cleanupScratchpadWindowResources(for: token)
                return nil
            }
            return entry
        }
    }

    func revealableScratchpadEntries(in index: ScratchpadIndex) -> [WindowState] {
        scratchpadEntries(in: index).filter { entry in
            !isManagedWindowSuspendedForNativeFullscreen(entry.token)
                && !workspaceManager.isWindowSuppressedByMacOS(entry.token)
        }
    }

    func revealScratchpadMembers(
        _ entries: [WindowState],
        in index: ScratchpadIndex,
        on workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        preferring preferredToken: WindowToken? = nil,
        focusOrigin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) -> Bool {
        for entry in scratchpadEntries(in: index) where entry.workspaceId != workspaceId {
            reassignManagedWindow(entry.token, to: workspaceId)
        }
        let resolvedEntries = entries.compactMap { workspaceManager.entry(for: $0.token) }
        let preferredToken = preferredToken ?? workspaceManager.lastFocusedToken(in: workspaceId)
        let ordered = resolvedEntries.filter { $0.token != preferredToken }
            + resolvedEntries.filter { $0.token == preferredToken }
        let orderedHandles = ordered.compactMap { workspaceManager.handle(for: $0.token) }
        var revealed = false
        let groupId = layoutRefreshController.revealGroups.begin(index: index) { [weak self] outcome in
            guard let self else { return }
            let revealedHandleIds = Set(outcome.revealedHandles.map(ObjectIdentifier.init))
            let survivors = orderedHandles.compactMap { handle -> WindowToken? in
                guard revealedHandleIds.contains(ObjectIdentifier(handle)),
                      self.workspaceManager.scratchpadIndex(for: handle.id) == index,
                      self.workspaceManager.entry(for: handle) != nil,
                      self.workspaceManager.hiddenState(for: handle.id) == nil
                else {
                    return nil
                }
                return handle.id
            }
            guard !survivors.isEmpty else {
                if self.workspaceManager.revealedScratchpadIndex() == index {
                    self.workspaceManager.setRevealedScratchpad(nil)
                    self.requestWorkspaceBarRefresh()
                }
                return
            }
            self.scratchpadStacking
                .stackScratchpadMembers(survivors, in: index, on: workspaceId, focusOrigin: focusOrigin)
        }

        for entry in ordered where showScratchpadWindow(
            entry,
            on: workspaceId,
            monitor: monitor,
            revealGroupId: groupId
        ) {
            revealed = true
        }

        guard revealed else {
            layoutRefreshController.revealGroups.discard(groupId)
            return false
        }
        layoutRefreshController.revealGroups.seal(groupId)
        requestWorkspaceBarRefresh()
        return true
    }

    func hideRevealedScratchpad(
        _ index: ScratchpadIndex,
        fallbackMonitor: Monitor,
        focusOrigin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) {
        let entries = scratchpadEntries(in: index).filter { entry in
            workspaceManager.hiddenState(for: entry.token) == nil
                || workspaceManager.isWindowSuppressedByMacOS(entry.token)
                || isManagedWindowSuspendedForNativeFullscreen(entry.token)
        }
        hideScratchpadMembers(entries, fallbackMonitor: fallbackMonitor, focusOrigin: focusOrigin)
        workspaceManager.setRevealedScratchpad(nil)
    }
}
