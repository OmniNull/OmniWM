// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, appTheming, styles, menuBar, network
    case workspaces, layouts, monitors, appRules, overview, windowSwitcher
    case hotkeys, mouseTrackpad, commandPalette, launcher, quakeTerminal, diagnostics, advanced

    var id: String {
        rawValue
    }

    var displayName: String {
        presentation.title
    }

    var icon: String {
        presentation.icon
    }

    var subtitle: String {
        presentation.subtitle
    }

    private struct Presentation {
        let title: String
        let icon: String
        let subtitle: String

        init(_ title: String, _ icon: String, _ subtitle: String) {
            self.title = title
            self.icon = icon
            self.subtitle = subtitle
        }
    }

    private var presentation: Presentation {
        switch self {
        case .general:
            Presentation(
                String(localized: "General"),
                "gearshape",
                String(localized: "Language, startup, and updates.")
            )
        case .appearance:
            Presentation(
                String(localized: "Appearance"),
                "paintpalette",
                String(localized: "Choose how OmniWM looks and moves.")
            )
        case .appTheming:
            Presentation(
                String(localized: "App Theming"),
                "paintbrush.pointed",
                String(localized: "Color Ghostty, kitty, herdr, Neovim and your own templates from OmniWM’s palette.")
            )
        case .styles:
            Presentation(
                String(localized: "Styles & Widgets"),
                "square.grid.2x2",
                String(localized: "Choose a style, then arrange its bar, island and drawers, and adjust its look.")
            )
        case .menuBar:
            Presentation(
                String(localized: "Menu Bar"),
                "menubar.arrow.up.rectangle",
                String(localized: "Manage OmniWM’s status item and hidden menu-bar apps.")
            )
        case .network:
            Presentation(
                String(localized: "Network & Permissions"),
                "network.badge.shield.half.filled",
                String(localized: "Review what OmniShell widgets, native programs, and built-in services can reach.")
            )
        case .workspaces:
            Presentation(
                String(localized: "Workspaces"),
                "rectangle.3.group",
                String(localized: "Organize workspaces and choose their layouts and home displays.")
            )
        case .layouts:
            Presentation(
                String(localized: "Layouts"),
                "rectangle.split.3x1",
                String(localized: "Tune window spacing, scrolling columns, and split layouts.")
            )
        case .monitors:
            Presentation(
                String(localized: "Displays"),
                "display.2",
                String(localized: "Set display arrangement, routing, and cross-display behavior.")
            )
        case .appRules:
            Presentation(
                String(localized: "App Rules"),
                "app.badge.checkmark",
                String(localized: "Choose how particular apps and windows are managed.")
            )
        case .overview:
            Presentation(
                String(localized: "Overview"),
                "rectangle.grid.2x2",
                String(localized: "Customize the workspace overview and its controls.")
            )
        case .windowSwitcher:
            Presentation(
                String(localized: "Window Switcher"),
                "rectangle.stack",
                String(localized: "Hold a shortcut to cycle through window previews.")
            )
        case .hotkeys:
            Presentation(
                String(localized: "Keyboard Shortcuts"),
                "keyboard",
                String(localized: "Find commands and assign keyboard or mouse shortcuts.")
            )
        case .mouseTrackpad:
            Presentation(
                String(localized: "Mouse & Trackpad"),
                "computermouse",
                String(localized: "Configure gestures, window manipulation, and pointer focus.")
            )
        case .commandPalette:
            Presentation(
                String(localized: "Command Palette"),
                "magnifyingglass",
                String(localized: "Choose how the palette searches windows, apps, commands, and files.")
            )
        case .launcher:
            Presentation(
                String(localized: "Launcher"), "square.grid.2x2",
                String(localized: "Launch apps, CLI tools, saved commands, and scripts.")
            )
        case .quakeTerminal:
            Presentation(
                String(localized: "Quake Terminal"),
                "terminal",
                String(localized: "Configure your drop-down terminal’s placement and appearance.")
            )
        case .diagnostics:
            Presentation(
                String(localized: "Troubleshooting"),
                "stethoscope",
                String(localized: "Check app health and record a problem or performance capture.")
            )
        case .advanced:
            Presentation(
                String(localized: "Advanced"),
                "slider.horizontal.3",
                String(localized: "Configuration files, scripting, and command-line tools.")
            )
        }
    }
}

enum SettingsSectionGroup: String, CaseIterable, Identifiable {
    case app, desktop, windows, input, tools, support
    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .app: String(localized: "App")
        case .desktop: String(localized: "Desktop")
        case .windows: String(localized: "Windows")
        case .input: String(localized: "Input")
        case .tools: String(localized: "Tools")
        case .support: String(localized: "Support")
        }
    }

    var sections: [SettingsSection] {
        switch self {
        case .app: [.general, .appearance, .appTheming]
        case .desktop: [.styles, .menuBar, .network]
        case .windows: [.workspaces, .layouts, .monitors, .appRules, .overview, .windowSwitcher]
        case .input: [.hotkeys, .mouseTrackpad]
        case .tools: [.commandPalette, .launcher, .quakeTerminal]
        case .support: [.diagnostics, .advanced]
        }
    }
}
