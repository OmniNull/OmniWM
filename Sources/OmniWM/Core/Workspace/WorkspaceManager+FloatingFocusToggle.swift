// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension WorkspaceManager {
    func isFloatingFocusToggleSource(
        _ focusedToken: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let focusedToken, let entry = entry(for: focusedToken) else { return false }
        return entry.workspaceId == workspaceId && entry.mode == .floating
    }

    func floatingFocusToggleTarget(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        let candidates = floatingEntries(in: workspaceId).filter { isFloatingWindowDisplayable($0) }
        if let remembered = lastFloatingFocusedToken(in: workspaceId),
           candidates.contains(where: { $0.token == remembered })
        {
            return remembered
        }
        return candidates.max { ($0.pid, $0.windowId) < ($1.pid, $1.windowId) }?.token
    }
}
