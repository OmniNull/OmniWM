// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

enum StatusMenuItem: String, CaseIterable, Identifiable {
    case hiddenIcons
    case settings
    case reportBug
    case appRules
    case openShellFolder
    case checkForUpdates
    case advanced
    case diagnostics
    case helpLinks
    case sponsors

    var id: String {
        rawValue
    }
}
