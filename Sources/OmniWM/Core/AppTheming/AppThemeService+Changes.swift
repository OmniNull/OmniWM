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

    func ghosttySelectionChanges() throws -> [AppThemeChange] {
        try preview.ghosttySelectionChanges()
    }

    func applyGhosttySelection(_ changes: [AppThemeChange]) {
        selection = changes
        markForceReload(AppThemeBuiltIn.ghostty.id)
        schedule()
    }
}
