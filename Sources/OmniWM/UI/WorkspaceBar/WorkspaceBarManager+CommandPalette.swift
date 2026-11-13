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
        let config = commandPaletteConfig
        if shellHost == nil { updateShellTheme(config) }
        let theme = resolvedCommandPaletteTheme(config)
        commandPaletteTheme = theme
        resources.refreshPalettes(theme: theme)
        return ShellCommandPaletteSource.make(
            config: config,
            shellDirectory: shellConfiguration.shellDirectory,
            resources: resources,
            permissions: shellPermissions,
            bundled: bundled
        )
    }

    func refreshCommandPaletteAppearance(ifThemeChanged: Bool = false) {
        guard let resources = commandPaletteResources else { return }
        let theme = resolvedCommandPaletteTheme(commandPaletteConfig)
        if ifThemeChanged, commandPaletteTheme == theme { return }
        commandPaletteTheme = theme
        resources.refreshPalettes(theme: theme)
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

    private func resolvedCommandPaletteTheme(_ config: ShellConfig) -> ShellTheme {
        let bar = controller?.settings.workspaceBar
        return ShellWidgetHost.paletteTheme(
            config: config,
            accent: bar?.accentColor,
            foreground: bar?.textColor
        )
    }
}
