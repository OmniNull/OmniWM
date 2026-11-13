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

    /// The window after `focusedToken` in the workspace's cycle of floating, then tiled
    /// windows, or the first window when it is not in the cycle. Nil when there is nowhere to go.
    func focusToggleTarget(
        after focusedToken: WindowToken? = nil,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        let floating = floatingEntries(in: workspaceId).filter { isFloatingWindowDisplayable($0) }
        let tiled = tiledEntries(in: workspaceId).filter {
            isFocusResolutionEligible($0, in: workspaceId, mode: .tiling)
        }
        let order = [floating, tiled].flatMap { entries in
            entries.map(\.token).sorted { ($0.pid, $0.windowId) < ($1.pid, $1.windowId) }
        }
        guard let focusedToken, let index = order.firstIndex(of: focusedToken) else { return order.first }
        let next = order[(index + 1) % order.count]
        return next == focusedToken ? nil : next
    }
}
