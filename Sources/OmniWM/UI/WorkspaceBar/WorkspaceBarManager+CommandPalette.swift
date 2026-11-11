// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension WorkspaceBarManager {
    var commandPaletteConfig: ShellConfig {
        if let shellHost { return shellHost.config }
        if !shellConfiguration.config.directories.isEmpty { return shellConfiguration.config }
        if let commandPaletteConfigCache { return commandPaletteConfigCache }
        let shellDirectory = shellConfiguration.shellDirectory
        if FileManager.default.fileExists(atPath: shellDirectory.path) {
            let backups = ShellDefaults.sync(into: shellDirectory)
            if !backups.isEmpty {
                Self.presentReplacedShellDefaults(backups)
            }
        }
        let config = ShellConfig.resolve(shellDirectory: shellDirectory)
        commandPaletteConfigCache = config
        return config
    }

    func commandPaletteFingerprint() -> [String: SettingsFileAccess.Fingerprint] {
        ShellCommandPaletteSource.fingerprint(
            config: commandPaletteConfig,
            shellDirectory: shellConfiguration.shellDirectory
        )
    }

    func commandPaletteSource(bundled: Bool = false) -> ShellCommandPaletteSource? {
        let resources = commandPaletteResources ?? makeCommandPaletteResources()
        refreshCommandPaletteColors(resources)
        return ShellCommandPaletteSource.make(
            config: commandPaletteConfig,
            shellDirectory: shellConfiguration.shellDirectory,
            resources: resources,
            permissions: shellPermissions,
            bundled: bundled
        )
    }

    func refreshCommandPaletteAppearance() {
        guard let resources = commandPaletteResources else { return }
        refreshCommandPaletteColors(resources)
        controller?.commandPaletteController.presentation.shell?.redraw()
    }

    private func makeCommandPaletteResources() -> ShellResources {
        let resources = makeShellResources()
        commandPaletteResources = resources
        commandPaletteColorsObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshCommandPaletteAppearance()
            }
        }
        return resources
    }

    private func refreshCommandPaletteColors(_ resources: ShellResources) {
        let bar = controller?.settings.workspaceBar
        resources.refreshPalettes(theme: ShellWidgetHost.paletteTheme(
            config: commandPaletteConfig,
            accent: bar?.accentColor,
            foreground: bar?.textColor
        ))
    }
}
