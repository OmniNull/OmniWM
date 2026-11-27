// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public enum IPCPresentationCommand: String, CaseIterable, Hashable, Sendable {
    case overview = "toggle-overview"
    case systemStats = "toggle-system-stats"
    case quakeTerminal = "toggle-quake-terminal"
    case workspaceBar = "toggle-workspace-bar"
    case hiddenBar = "hidden-bar-panel"
}
