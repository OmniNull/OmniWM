// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation

enum AppThemeTerminalColors: String, Codable, CaseIterable, Equatable, Sendable {
    case palette
    case standard
}

enum AppThemeCustomReload: String, Codable, CaseIterable, Equatable, Sendable {
    case none
    case ghostty
    case kitty
    case herdr
}

struct AppThemingApp: Codable, Equatable {
    var enabled = false

    init(enabled: Bool = false) {
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

struct AppThemingHerdr: Codable, Equatable {
    var enabled = false
    var reloadSavedMachines = true

    init(enabled: Bool = false, reloadSavedMachines: Bool = true) {
        self.enabled = enabled
        self.reloadSavedMachines = reloadSavedMachines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        reloadSavedMachines = try container.decodeIfPresent(Bool.self, forKey: .reloadSavedMachines) ?? true
    }
}

struct AppThemingCustom: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var enabled: Bool
    var template: String
    var darkTemplate: String?
    var output: String
    var reload: AppThemeCustomReload

    init(
        id: String = UUID().uuidString,
        name: String,
        enabled: Bool = true,
        template: String,
        darkTemplate: String? = nil,
        output: String,
        reload: AppThemeCustomReload = .none
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.template = template
        self.darkTemplate = darkTemplate
        self.output = output
        self.reload = reload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        template = try container.decodeIfPresent(String.self, forKey: .template) ?? ""
        darkTemplate = try container.decodeIfPresent(String.self, forKey: .darkTemplate)
        output = try container.decodeIfPresent(String.self, forKey: .output) ?? ""
        reload = try container.decodeIfPresent(String.self, forKey: .reload)
            .flatMap(AppThemeCustomReload.init(rawValue:))
            ?? .none
    }

    var targetID: String {
        "custom-\(id)"
    }
}

extension SettingsExport {
    struct AppTheming: Codable, Equatable {
        typealias App = AppThemingApp
        typealias Herdr = AppThemingHerdr
        typealias Custom = AppThemingCustom

        var terminalColors = AppThemeTerminalColors.palette
        var ghostty = App()
        var kitty = App()
        var herdr = Herdr()
        var neovim = App()
        var custom: [Custom] = []

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            terminalColors = try container.decodeIfPresent(String.self, forKey: .terminalColors)
                .flatMap(AppThemeTerminalColors.init(rawValue:)) ?? .palette
            ghostty = try container.decodeIfPresent(App.self, forKey: .ghostty) ?? App()
            kitty = try container.decodeIfPresent(App.self, forKey: .kitty) ?? App()
            herdr = try container.decodeIfPresent(Herdr.self, forKey: .herdr) ?? Herdr()
            neovim = try container.decodeIfPresent(App.self, forKey: .neovim) ?? App()
            custom = try container.decodeIfPresent([Custom].self, forKey: .custom) ?? []
        }

        func isEnabled(_ app: AppThemeBuiltIn) -> Bool {
            switch app {
            case .ghostty: ghostty.enabled
            case .kitty: kitty.enabled
            case .herdr: herdr.enabled
            case .neovim: neovim.enabled
            }
        }

        mutating func setEnabled(_ app: AppThemeBuiltIn, _ enabled: Bool) {
            switch app {
            case .ghostty: ghostty.enabled = enabled
            case .kitty: kitty.enabled = enabled
            case .herdr: herdr.enabled = enabled
            case .neovim: neovim.enabled = enabled
            }
        }

        var anyEnabled: Bool {
            AppThemeBuiltIn.allCases.contains(where: isEnabled) || custom.contains(where: \.enabled)
        }

        func targets(configHome: URL) -> [AppThemeTarget] {
            let builtIns = AppThemeBuiltIn.allCases.filter(isEnabled).map { app in
                AppThemeTarget(
                    id: app.id,
                    name: app.name,
                    outputs: app.outputs(configHome: configHome),
                    reload: app.reload(savedMachines: herdr.reloadSavedMachines)
                )
            }
            return builtIns + custom.filter(\.enabled).map { $0.target(savedMachines: herdr.reloadSavedMachines) }
        }
    }
}

extension AppThemingCustom {
    func target(savedMachines: Bool) -> AppThemeTarget {
        let reloadAction: AppThemeReloadAction? = switch reload {
        case .none: nil
        case .ghostty: .ghostty
        case .kitty: .kitty
        case .herdr: .herdr(savedMachines: savedMachines)
        }
        let dark = darkTemplate.flatMap { $0.isEmpty ? nil : AppThemeTemplateSource.file($0) }
        return AppThemeTarget(
            id: targetID,
            name: name,
            outputs: [AppThemeOutput(path: output, template: .file(template), darkTemplate: dark)],
            reload: reloadAction
        )
    }
}

@MainActor @Observable
final class AppThemingSettings {
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onValuesChange: (() -> Void)?

    var values = SettingsExport.AppTheming() {
        didSet {
            guard values != oldValue else { return }
            onChange?()
            onValuesChange?()
        }
    }

    func export() -> SettingsExport.AppTheming {
        values
    }

    func apply(_ next: SettingsExport.AppTheming) {
        values = next
    }
}
