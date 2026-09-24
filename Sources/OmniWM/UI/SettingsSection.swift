// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case diagnostics
    case niri
    case dwindle
    case monitors
    case workspaces
    case overview
    case borders
    case bar
    case hiddenBar
    case hotkeys
    case mouseTrackpad
    case quakeTerminal
    case reportIssue

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .general: String(localized: "General")
        case .diagnostics: String(localized: "Troubleshooting")
        case .niri: String(localized: "Niri Layout")
        case .dwindle: String(localized: "Dwindle Layout")
        case .monitors: String(localized: "Monitors")
        case .workspaces: String(localized: "Workspaces")
        case .overview: String(localized: "Overview")
        case .borders: String(localized: "Borders")
        case .bar: String(localized: "Workspace Bar")
        case .hiddenBar: String(localized: "Hidden Bar")
        case .hotkeys: String(localized: "Hotkeys")
        case .mouseTrackpad: String(localized: "Mouse & Trackpad")
        case .quakeTerminal: String(localized: "Quake Terminal")
        case .reportIssue: String(localized: "Report an Issue")
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .diagnostics: "stethoscope"
        case .niri: "scroll"
        case .dwindle: "square.split.2x2"
        case .monitors: "display"
        case .workspaces: "rectangle.3.group"
        case .overview: "rectangle.grid.2x2"
        case .borders: "square.dashed"
        case .bar: "menubar.rectangle"
        case .hiddenBar: "eye.slash"
        case .hotkeys: "keyboard"
        case .mouseTrackpad: "computermouse"
        case .quakeTerminal: "terminal"
        case .reportIssue: "ladybug"
        }
    }
}

enum SettingsSectionGroup: String, CaseIterable, Identifiable {
    case basics = "Basics"
    case layouts = "Layouts"
    case workspace = "Workspace"
    case input = "Input"
    case help = "Help"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .basics: String(localized: "Basics")
        case .layouts: String(localized: "Layouts")
        case .workspace: String(localized: "Workspace")
        case .input: String(localized: "Input")
        case .help: String(localized: "Help")
        }
    }

    var sections: [SettingsSection] {
        switch self {
        case .basics:
            [.general]
        case .layouts:
            [.niri, .dwindle, .monitors]
        case .workspace:
            [.workspaces, .overview, .borders, .bar, .hiddenBar]
        case .input:
            [.hotkeys, .mouseTrackpad, .quakeTerminal]
        case .help:
            [.reportIssue, .diagnostics]
        }
    }
}
