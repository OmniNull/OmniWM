// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Observation

extension SettingsExport {
    struct WindowSwitcher: Codable, Equatable {
        var enabled = false
        var scope = WindowSwitcherScope.allWorkspaces
        var commandTab = WindowSwitcherShortcuts().commandTab
        var optionTab = WindowSwitcherShortcuts().optionTab
        var showFooter = true

        var shortcuts: WindowSwitcherShortcuts {
            WindowSwitcherShortcuts(commandTab: commandTab, optionTab: optionTab)
        }
    }
}

extension SettingsExport.WindowSwitcher {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        scope = try container.decode(WindowSwitcherScope.self, forKey: .scope)
        commandTab = try container.decodeIfPresent(WindowSwitcherShortcutScope.self, forKey: .commandTab) ?? .remembered
        optionTab = try container.decodeIfPresent(WindowSwitcherShortcutScope.self, forKey: .optionTab) ?? .disabled
        showFooter = try container.decodeIfPresent(Bool.self, forKey: .showFooter) ?? true
    }
}

@MainActor @Observable
final class WindowSwitcherSettings {
    private nonisolated static let defaults = SettingsExport.WindowSwitcher()
    @ObservationIgnored var onChange: (() -> Void)?

    var enabled = WindowSwitcherSettings.defaults.enabled {
        didSet { onChange?() }
    }

    var scope = WindowSwitcherSettings.defaults.scope {
        didSet { onChange?() }
    }

    var commandTab = WindowSwitcherSettings.defaults.commandTab {
        didSet { onChange?() }
    }

    var optionTab = WindowSwitcherSettings.defaults.optionTab {
        didSet { onChange?() }
    }

    var showFooter = WindowSwitcherSettings.defaults.showFooter {
        didSet { onChange?() }
    }

    func export() -> SettingsExport.WindowSwitcher {
        SettingsExport.WindowSwitcher(
            enabled: enabled, scope: scope, commandTab: commandTab, optionTab: optionTab, showFooter: showFooter
        )
    }

    func apply(_ values: SettingsExport.WindowSwitcher) {
        enabled = values.enabled
        scope = values.scope
        commandTab = values.commandTab
        optionTab = values.optionTab
        showFooter = values.showFooter
    }
}
