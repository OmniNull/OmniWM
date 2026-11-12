// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension AppThemeService {
    func target(for app: AppThemeBuiltIn) -> AppThemeTarget {
        AppThemeTarget(
            id: app.id,
            name: app.name,
            outputs: app.outputs(configHome: configHome),
            reload: app.reload(savedMachines: settings.values.herdr.reloadSavedMachines)
        )
    }

    func outputPaths(for target: AppThemeTarget) -> [String] {
        target.outputs.map { output in
            (try? engine.policy.destination(for: output.path)).map(engine.policy.display) ?? output.path
        }
    }

    func changes(for target: AppThemeTarget, onlyExisting: Bool) throws -> [AppThemeChange] {
        guard let palette else { return [] }
        let job = AppThemeJob(palette: palette, dark: isDark, appearanceChanged: false, targets: [target])
        return try target.outputs.compactMap { output in
            let rendered = try engine.render(output, job: job)
            guard rendered.before != rendered.after, !onlyExisting || rendered.before != nil else { return nil }
            return AppThemeChange(
                url: rendered.url,
                display: rendered.display,
                before: rendered.before.map { String(decoding: $0, as: UTF8.self) },
                after: String(decoding: rendered.after, as: UTF8.self),
                beforeDigest: rendered.before.map { AppThemeFileWriter.digest($0) }
            )
        }
    }

    func confirm(
        _ changes: [AppThemeChange],
        enabling app: AppThemeBuiltIn? = nil,
        reloading targetID: String? = nil
    ) throws {
        for change in changes {
            if let digest = change.beforeDigest { markTakeOver(change.url.path, reviewed: digest) }
        }
        if let targetID { markForceReload(targetID) }
        if let app, !settings.values.isEnabled(app) {
            settings.values.setEnabled(app, true)
        } else {
            schedule()
        }
    }

    private var ghosttyFiles: [(url: URL, text: String)] {
        AppThemeGhosttySelection.loadedFiles(configHome: configHome, home: engine.policy.home).compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { (url, $0) }
        }
    }

    func ghosttySelectionStatus() -> AppThemeGhosttyStatus {
        switch AppThemeGhosttySelection.status(ghosttyFiles) {
        case let .overridden(path): .overridden(engine.policy.display(URL(fileURLWithPath: path)))
        case let status: status
        }
    }

    func ghosttySelectionChanges() -> [AppThemeChange] {
        let fallback = AppThemeGhosttySelection.candidates(configHome: configHome, home: engine.policy.home)[0]
        let plans = AppThemeGhosttySelection.plan(ghosttyFiles, fallback: fallback)
        let blocked = plans.filter { (try? engine.policy.destination(for: $0.url.path)) == nil }
        var changes = plans.compactMap { plan -> AppThemeChange? in
            guard let url = try? engine.policy.destination(for: plan.url.path) else { return nil }
            return AppThemeChange(url: url, display: engine.policy.display(url), before: plan.before, after: plan.after)
        }
        if !blocked.isEmpty, !changes.isEmpty {
            changes[0].note = String(
                localized: "\(blocked.map { engine.policy.display($0.url) }.joined(separator: ", ")) also sets a theme but is outside the folders OmniWM writes. Comment that line out yourself."
            )
        }
        return changes
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
