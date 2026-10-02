// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

enum WindowSwitcherScope: String, Codable, CaseIterable, Sendable {
    case allWorkspaces
    case activeWorkspace
}

enum WindowSwitcherShortcutScope: String, Codable, CaseIterable, Sendable {
    case disabled
    case remembered
    case activeWorkspace
    case allWorkspaces

    var initialScope: WindowSwitcherScope? {
        switch self {
        case .disabled,
             .remembered: nil
        case .activeWorkspace: .activeWorkspace
        case .allWorkspaces: .allWorkspaces
        }
    }
}

struct WindowSwitcherShortcuts: Equatable, Sendable {
    var commandTab = WindowSwitcherShortcutScope.activeWorkspace
    var optionTab = WindowSwitcherShortcutScope.allWorkspaces

    var isEnabled: Bool {
        commandTab != .disabled || optionTab != .disabled
    }
}
