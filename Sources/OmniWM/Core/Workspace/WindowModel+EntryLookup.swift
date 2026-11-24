// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WindowModel {
    func entry(for token: WindowToken) -> WindowState? {
        entries[token]
    }

    func entry(for handle: WindowHandle) -> WindowState? {
        entry(for: handle.id)
    }

    func entry(forPid pid: pid_t, windowId: Int) -> WindowState? {
        entry(for: WindowToken(pid: pid, windowId: windowId))
    }

    func entry(forWindowId windowId: Int, inVisibleWorkspaces visibleIds: Set<WorkspaceDescriptor.ID>) -> WindowState? {
        guard let entry = entry(forWindowId: windowId),
              visibleIds.contains(entry.workspaceId) else { return nil }
        return entry
    }
}
