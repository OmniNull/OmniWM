// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct AppThemePreview {
    let engine: AppThemeEngine
    let values: SettingsExport.AppTheming
    let dark: Bool
    let palette: () -> AppThemePalette?

    var configHome: URL {
        engine.policy.configHome
    }

    func target(for app: AppThemeBuiltIn) -> AppThemeTarget {
        AppThemeTarget(
            id: app.id,
            name: app.name,
            outputs: app.outputs(configHome: configHome),
            reload: app.reload(savedMachines: values.herdr.reloadSavedMachines)
        )
    }

    func target(for custom: AppThemingCustom) -> AppThemeTarget {
        custom.target(savedMachines: values.herdr.reloadSavedMachines)
    }

    func outputPaths(for target: AppThemeTarget) -> [String] {
        target.outputs.map { output in
            (try? engine.policy.destination(for: output.path)).map(engine.policy.display) ?? output.path
        }
    }

    func changes(for target: AppThemeTarget, onlyExisting: Bool) throws -> [AppThemeChange] {
        guard let palette = palette() else { return [] }
        let job = AppThemeJob(palette: palette, dark: dark, appearanceChanged: false, targets: [target])
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

    private var ghosttyFiles: [(url: URL, text: String, digest: String)] {
        AppThemeGhosttySelection.loadedFiles(configHome: configHome, home: engine.policy.home).compactMap { url in
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return (url, text, AppThemeFileWriter.digest(data))
        }
    }

    func ghosttySelectionStatus() -> AppThemeGhosttyStatus {
        switch AppThemeGhosttySelection.status(ghosttyFiles.map { ($0.url, $0.text) }) {
        case let .overridden(path): .overridden(engine.policy.display(URL(fileURLWithPath: path)))
        case let status: status
        }
    }

    func ghosttySelectionChanges() -> [AppThemeChange] {
        let fallback = AppThemeGhosttySelection.candidates(configHome: configHome, home: engine.policy.home)[0]
        let files = ghosttyFiles
        let plans = AppThemeGhosttySelection.plan(files.map { ($0.url, $0.text) }, fallback: fallback)
        let blocked = plans.filter { (try? engine.policy.destination(for: $0.url.path)) == nil }
        var changes = plans.compactMap { plan -> AppThemeChange? in
            guard let url = try? engine.policy.destination(for: plan.url.path) else { return nil }
            return AppThemeChange(
                url: url,
                display: engine.policy.display(url),
                before: plan.before,
                after: plan.after,
                beforeDigest: files.first { $0.url == plan.url }?.digest
            )
        }
        if !blocked.isEmpty, !changes.isEmpty {
            changes[0].note = String(
                localized: "\(blocked.map { engine.policy.display($0.url) }.joined(separator: ", ")) also sets a theme but is outside the folders OmniWM writes. Comment that line out yourself."
            )
        }
        return changes
    }
}
