// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Observation

enum WindowSwitcherScope: String, Codable, CaseIterable {
    case allWorkspaces
    case activeWorkspace
}

extension SettingsExport {
    struct WindowSwitcher: Codable, Equatable {
        var enabled = false
        var scope = WindowSwitcherScope.allWorkspaces
    }
}

@MainActor @Observable
final class WindowSwitcherSettings {
    @ObservationIgnored var onChange: (() -> Void)?

    var enabled = false {
        didSet { onChange?() }
    }

    var scope = WindowSwitcherScope.allWorkspaces {
        didSet { onChange?() }
    }

    func export() -> SettingsExport.WindowSwitcher {
        SettingsExport.WindowSwitcher(enabled: enabled, scope: scope)
    }

    func apply(_ values: SettingsExport.WindowSwitcher) {
        enabled = values.enabled
        scope = values.scope
    }
}
