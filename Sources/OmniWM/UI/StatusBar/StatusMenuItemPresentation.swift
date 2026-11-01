// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

extension StatusMenuItem {
    var title: String {
        switch self {
        case .hiddenIcons: String(localized: "Show Hidden Icons")
        case .settings: String(localized: "Settings")
        case .reportBug: String(localized: "Report a Bug…")
        case .appRules: String(localized: "App Rules")
        case .openShellFolder: String(localized: "Open Shell Folder")
        case .checkForUpdates: String(localized: "Check for Updates...")
        case .advanced: String(localized: "Advanced")
        case .diagnostics: String(localized: "Diagnostics")
        case .helpLinks: String(localized: "Help & Links")
        case .sponsors: String(localized: "Omni Sponsors")
        }
    }

    var icon: String {
        switch self {
        case .hiddenIcons: "eye"
        case .settings: "gearshape"
        case .reportBug: "ladybug"
        case .appRules: "slider.horizontal.3"
        case .openShellFolder: "folder"
        case .checkForUpdates: "arrow.down.circle"
        case .advanced: "slider.horizontal.3"
        case .diagnostics: "stethoscope"
        case .helpLinks: "questionmark.circle"
        case .sponsors: "sparkles"
        }
    }
}
