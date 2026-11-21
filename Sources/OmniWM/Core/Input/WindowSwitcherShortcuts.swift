// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

enum WindowSwitcherScope: String, Codable, CaseIterable, Sendable {
    case allWorkspaces
    case visibleWorkspaces
    case activeWorkspace

    func next(offeringVisibleWorkspaces: Bool) -> WindowSwitcherScope {
        switch self {
        case .activeWorkspace: offeringVisibleWorkspaces ? .visibleWorkspaces : .allWorkspaces
        case .visibleWorkspaces: .allWorkspaces
        case .allWorkspaces: .activeWorkspace
        }
    }
}

enum WindowSwitcherShortcutScope: String, Codable, CaseIterable, Sendable {
    case disabled
    case remembered
    case activeWorkspace
    case visibleWorkspaces
    case allWorkspaces

    var initialScope: WindowSwitcherScope? {
        switch self {
        case .disabled,
             .remembered: nil
        case .activeWorkspace: .activeWorkspace
        case .visibleWorkspaces: .visibleWorkspaces
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
