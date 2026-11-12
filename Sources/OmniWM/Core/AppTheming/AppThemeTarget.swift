// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import os

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

enum AppThemeReloadAction: Hashable, Sendable {
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
    var enabled = AppThemeEnabledTargets.all
    var selection: [AppThemeChange] = []
}

final class AppThemeEnabledTargets: Sendable {
    static let all = AppThemeEnabledTargets(nil)

    private struct Current {
        var ids: Set<String>?
        var targets: [String: AppThemeTarget] = [:]
    }

    private let current: OSAllocatedUnfairLock<Current>

    init(_ ids: Set<String>?) {
        current = OSAllocatedUnfairLock(initialState: Current(ids: ids))
    }

    func contains(_ id: String) -> Bool {
        current.withLock { $0.ids?.contains(id) ?? true }
    }

    func contains(_ target: AppThemeTarget) -> Bool {
        current.withLock { current in
            guard current.ids?.contains(target.id) ?? true else { return false }
            return current.targets[target.id].map { $0 == target } ?? true
        }
    }

    func set(_ next: Set<String>) {
        current.withLock { $0 = Current(ids: next) }
    }

    func set(targets next: [AppThemeTarget]) {
        current.withLock { current in
            current = Current(
                ids: Set(next.map(\.id)),
                targets: Dictionary(next.map { ($0.id, $0) }) { first, _ in first }
            )
        }
    }
}

struct AppThemeRunReport: Sendable {
    var results: [String: AppThemeResult] = [:]
    var stored: [String: AppThemeResult] = [:]
    var ghosttyThemesChanged = false
    var backups: [URL] = []
    var reviewAgain: [String] = []
    var selectionProblem: String?
}
