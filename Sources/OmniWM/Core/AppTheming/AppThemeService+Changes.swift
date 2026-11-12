// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension AppThemeService {
    var preview: AppThemePreview {
        AppThemePreview(engine: engine, values: settings.values, dark: isDark) { [weak self] in self?.palette }
    }

    func target(for app: AppThemeBuiltIn) -> AppThemeTarget {
        preview.target(for: app)
    }

    func outputPaths(for target: AppThemeTarget) -> [String] {
        preview.outputPaths(for: target)
    }

    func changes(for target: AppThemeTarget, onlyExisting: Bool) throws -> [AppThemeChange] {
        try preview.changes(for: target, onlyExisting: onlyExisting)
    }

    func approve(_ changes: [AppThemeChange]) {
        for change in changes {
            if let digest = change.beforeDigest { markTakeOver(change.url.path, reviewed: digest) }
        }
    }

    func confirm(
        _ changes: [AppThemeChange],
        enabling app: AppThemeBuiltIn? = nil,
        reloading targetID: String? = nil
    ) {
        approve(changes)
        if let targetID { markForceReload(targetID) }
        if let app, !settings.values.isEnabled(app) {
            settings.values.setEnabled(app, true)
        } else {
            schedule()
        }
    }

    func ghosttySelectionStatus() -> AppThemeGhosttyStatus {
        preview.ghosttySelectionStatus()
    }

    func ghosttySelectionChanges() -> [AppThemeChange] {
        preview.ghosttySelectionChanges()
    }

    func applyGhosttySelection(_ changes: [AppThemeChange]) throws {
        let stale = changes.filter { change in
            (try? String(contentsOf: change.url, encoding: .utf8)) != change.before
        }
        guard stale.isEmpty else { throw AppThemeEngineError.changedOutsideOmniWM(stale.map(\.display)) }
        for change in changes {
            if let before = change.before {
                lastBackup = try engine.store.backup(Data(before.utf8), of: change.url)
            }
        }
        for change in changes {
            try AppThemeFileWriter.writeAtomically(Data(change.after.utf8), to: change.url)
        }
        markForceReload(AppThemeBuiltIn.ghostty.id)
        schedule()
        if !isRunning { onRunFinished?() }
    }
}
