// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WorkspaceManager {
    func isFloatingFocusToggleSource(
        _ focusedToken: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let focusedToken, let entry = entry(for: focusedToken) else { return false }
        return entry.workspaceId == workspaceId && entry.mode == .floating
    }

    func isFloatingFocusCycleMember(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let entry = entry(for: token) else { return false }
        return entry.workspaceId == workspaceId && isFloatingWindowDisplayable(entry)
    }

    // Default mode. From a tiled window, go to the remembered floating window. Each later press
    // goes to the next floating window, and the press that would come back to `cycleStart`
    // returns to the remembered tiled window instead.
    func floatingFocusToggleTarget(
        after focusedToken: WindowToken?,
        cycleStart: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        let floating = floatingFocusCycle(in: workspaceId)
        guard let focusedToken, let index = floating.firstIndex(of: focusedToken) else {
            if let remembered = lastFloatingFocusedToken(in: workspaceId), floating.contains(remembered) {
                return remembered
            }
            return floating.first
        }
        let start = cycleStart.flatMap { floating.contains($0) ? $0 : nil } ?? focusedToken
        let next = floating[(index + 1) % floating.count]
        if next != start {
            return next
        }
        if let tiled = preferredFocusToken(in: workspaceId) {
            return tiled
        }
        return next == focusedToken ? nil : next
    }

    // Opt-in mode. The window after `focusedToken` in one ring of the workspace's floating
    // windows, then its tiled windows. Nil when there is nowhere to go.
    func focusToggleCycleAllTarget(
        after focusedToken: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        let tiled = tiledEntries(in: workspaceId)
            .filter { isFocusToggleRevealableTile($0, in: workspaceId) }
            .map(\.token)
            .sorted { ($0.pid, $0.windowId) < ($1.pid, $1.windowId) }
        let order = floatingFocusCycle(in: workspaceId) + tiled
        guard let focusedToken, let index = order.firstIndex(of: focusedToken) else { return order.first }
        let next = order[(index + 1) % order.count]
        return next == focusedToken ? nil : next
    }

    // An inactive Niri tab or a column parked off-screen is hidden only by the layout, and
    // navigating to it reveals it.
    private func isFocusToggleRevealableTile(_ entry: WindowState, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard entry.workspaceId == workspaceId,
              entry.mode == .tiling,
              !isWindowSuppressedByMacOS(entry)
        else { return false }
        guard let hiddenState = entry.hiddenState else { return true }
        return hiddenState.workspaceInactive || hiddenState.offscreenSide != nil
    }

    private func floatingFocusCycle(in workspaceId: WorkspaceDescriptor.ID) -> [WindowToken] {
        floatingEntries(in: workspaceId)
            .filter { isFloatingWindowDisplayable($0) }
            .map(\.token)
            .sorted { ($0.pid, $0.windowId) < ($1.pid, $1.windowId) }
    }
}
