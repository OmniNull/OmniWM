// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellCommandPaletteSource {
    let config: ShellConfig
    let bundled: Bool
    let fingerprint: [String: SettingsFileAccess.Fingerprint]
    let source: ShellWidgetSource
    let directories: [URL]
    let resources: ShellResources
    let permissions: ShellNetworkPermissions

    static func fingerprint(config: ShellConfig, shellDirectory: URL) -> [String: SettingsFileAccess.Fingerprint] {
        input(config: config, shellDirectory: shellDirectory, bundled: false).map {
            ShellWidgetSourceLoader.fingerprint($0)
        } ?? [:]
    }

    @MainActor
    static func make(
        config: ShellConfig,
        shellDirectory: URL,
        resources: ShellResources,
        permissions: ShellNetworkPermissions,
        bundled: Bool = false
    ) -> ShellCommandPaletteSource? {
        guard let input = input(config: config, shellDirectory: shellDirectory, bundled: bundled) else { return nil }
        let fingerprint = fingerprint(config: config, shellDirectory: shellDirectory)
        do {
            return try ShellCommandPaletteSource(
                config: config,
                bundled: input.sourceURL == ShellConfig.bundledWidget(ShellWidgetHost.commandPaletteWidget),
                fingerprint: fingerprint,
                source: ShellWidgetSourceLoader.build(input),
                directories: [input.sourceURL.deletingLastPathComponent()] + config.directories,
                resources: resources,
                permissions: permissions
            )
        } catch {
            Log.shell.error("Could not load the command palette widget: \(error.localizedDescription)")
            return nil
        }
    }

    private static func input(
        config: ShellConfig,
        shellDirectory: URL,
        bundled: Bool
    ) -> ShellWidgetSourceLoader.Input? {
        let name = ShellWidgetHost.commandPaletteWidget
        guard let url = (bundled ? nil : config.widget(name)) ?? ShellConfig.bundledWidget(name) else { return nil }
        return ShellWidgetSourceLoader.Input(
            name: name,
            shellDirectory: shellDirectory,
            sourceURL: url,
            directories: config.directories,
            profile: config.profile
        )
    }
}

extension ShellWidgetHost {
    nonisolated static let commandPaletteWidget = "command-palette"
}
