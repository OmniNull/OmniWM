// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellCommandPaletteSource {
    let config: ShellConfig
    let fingerprint: [String: SettingsFileAccess.Fingerprint]
    let source: ShellWidgetSource
    let directories: [URL]
    let resources: ShellResources
    let resourceStore: ShellResourceStore
    let permissions: ShellNetworkPermissions
}

extension ShellWidgetHost {
    nonisolated static let commandPaletteWidget = "command-palette"

    private var commandPaletteURL: URL? {
        config.widget(Self.commandPaletteWidget) ?? ShellConfig.bundledWidget(Self.commandPaletteWidget)
    }

    func commandPaletteFingerprint() -> [String: SettingsFileAccess.Fingerprint] {
        commandPaletteURL.map(fingerprint(of:)) ?? [:]
    }

    func commandPaletteSource() -> ShellCommandPaletteSource? {
        guard let url = commandPaletteURL else { return nil }
        let state = WidgetState(name: Self.commandPaletteWidget, sourceURL: url)
        do {
            return try ShellCommandPaletteSource(
                config: config,
                fingerprint: fingerprint(of: url),
                source: widgetSource(of: state),
                directories: folders(of: state),
                resources: resources,
                resourceStore: resourceStore,
                permissions: permissions
            )
        } catch {
            Log.shell.error("Could not load the command palette widget: \(error.localizedDescription)")
            return nil
        }
    }
}
