// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum AppThemeVariant: String, Codable, Equatable, Sendable {
    case current
    case light
    case dark
}

enum AppThemeTemplateSource: Equatable, Sendable {
    case text(String)
    case file(String)
}

struct AppThemeOutput: Equatable, Sendable {
    let path: String
    let template: AppThemeTemplateSource
    var darkTemplate: AppThemeTemplateSource?
    var variant = AppThemeVariant.current
    var table: [String]?
}

enum AppThemeReloadAction: Equatable, Sendable {
    case ghostty
    case kitty
    case herdr(savedMachines: Bool)
    case neovim

    var phase: Int {
        switch self {
        case .ghostty,
             .kitty: 0
        case .neovim: 1
        case .herdr: 2
        }
    }

    var runsAfterTerminals: Bool {
        if case .herdr = self { true } else { false }
    }
}

struct AppThemeTarget: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let outputs: [AppThemeOutput]
    let reload: AppThemeReloadAction?

    var isTerminal: Bool {
        reload == .ghostty || reload == .kitty
    }
}

struct AppThemeResult: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Equatable, Sendable {
        case updated
        case unchanged
        case failed
        case conflict
    }

    var date: Date
    var outcome: Outcome
    var message: String
    var reload: String?
    var reloadFailed = false
    var conflictPaths: [String] = []
}

struct AppThemeJob: Sendable {
    let palette: AppThemePalette
    let dark: Bool
    let appearanceChanged: Bool
    let targets: [AppThemeTarget]
    var takeOver: [String: String] = [:]
    var forceReload: Set<String> = []
}

struct AppThemeRunReport: Sendable {
    var results: [String: AppThemeResult] = [:]
    var ghosttyThemesChanged = false
    var backups: [URL] = []
}
