// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension SettingsFilePersistence {
    nonisolated static var fileURL: URL {
        settingsURL(in: defaultDirectoryURL)
    }

    nonisolated static func settingsURL(in directory: URL) -> URL {
        let luau = directory.appendingPathComponent(fileName, isDirectory: false)
        let toml = directory.appendingPathComponent("settings.toml", isDirectory: false)
        let fileManager = FileManager.default
        if (try? fileManager.attributesOfItem(atPath: luau.path)) == nil,
           (try? fileManager.attributesOfItem(atPath: toml.path)) != nil
        {
            return toml
        }
        return luau
    }

    private struct LaunchDocument {
        let url: URL
        let fingerprint: SettingsFileAccess.Fingerprint
        let load: SettingsFileLoad
    }

    private static var launchDocument: LaunchDocument?

    static func launchLanguage(at url: URL) -> String? {
        guard let target = try? SettingsFileAccess.settingsTarget(for: url),
              let contents = try? SettingsFileAccess.readContents(
                  at: target,
                  maximumBytes: ConfigScriptLoader.sourceLimit
              ) else { return nil }
        let load = SettingsFileLoad(contents.data, at: url)
        launchDocument = LaunchDocument(url: url, fingerprint: contents.fingerprint, load: load)
        guard let doc = try? load.result.get(), (try? validate(doc.export, monitorProvider: Monitor.current)) != nil,
              load.modules.isCurrent else { return nil }
        return doc.export.language
    }

    static func takeLaunchLoad(at url: URL, fingerprint: SettingsFileAccess.Fingerprint) -> SettingsFileLoad? {
        defer { launchDocument = nil }
        guard let cached = launchDocument, cached.url == url, cached.fingerprint == fingerprint,
              cached.load.modules.isCurrent else { return nil }
        return cached.load
    }

    static func validate(_ export: SettingsExport, monitorProvider: () -> [Monitor]) throws {
        try OverviewInputSettingsValidation.validate(
            mouseButton: export.overview.mouseButton,
            hyperTrigger: export.systemHyperTrigger,
            hotkeyBindings: export.hotkeyBindings
        )
        try GestureSettingsValidation.validate(export, monitorProvider: monitorProvider)
    }
}
