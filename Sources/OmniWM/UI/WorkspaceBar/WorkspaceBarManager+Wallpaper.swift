// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WorkspaceBarManager {
    func attachWallpaper(to host: ShellWidgetHost) {
        controller?.wallpaperManager.palette = host
        host.onWallpaperCommand = { [weak self] command in
            self?.performWallpaperCommand(command)
        }
    }

    func performWallpaperCommand(_ command: ShellWallpaperCommand) {
        guard let controller else { return }
        switch command {
        case let .scheme(scheme):
            selectWallpaperScheme(scheme)
        case .settings:
            controller.statusBarController?.openSettings(section: .wallpaper)
        default:
            controller.wallpaperManager.perform(command, chooseFolder: WallpaperManager.chooseFolder(startingAt:))
        }
    }

    var wallpaperPaletteState: WallpaperPaletteState {
        let config = shellHost?.config ?? shellConfiguration.config
        return WallpaperPaletteState(
            active: config.themeName == ShellWallpaperPalette.themeName,
            scheme: config.wallpaperScheme
        )
    }

    func selectWallpaperScheme(_ scheme: ShellWallpaperScheme) {
        guard let controller, let shellDirectory else { return }
        let manager = controller.wallpaperManager
        if let pixels = manager.palettePixels() ?? manager.mainPixels() {
            let destination = shellDirectory.appendingPathComponent("themes/\(ShellWallpaperPalette.themeName).toml")
            do {
                _ = try ShellWallpaperPaletteWriter.publish(
                    ShellWallpaperPalette.theme(pixels: pixels, scheme: scheme), to: destination
                )
            } catch {
                Log.shell.error("Failed to write the wallpaper palette: \(error.localizedDescription)")
            }
        }
        Task { @MainActor [weak self] in
            _ = await self?.applyShellFileRequest(.theme(
                name: ShellWallpaperPalette.themeName,
                scheme: scheme.rawValue
            ))
            self?.shellHost?.wallpaperPaletteDidChange()
        }
    }

    func useStylePalette() {
        let style = (shellHost?.config ?? shellConfiguration.config).styleThemeName
        let theme = style == ShellWallpaperPalette.themeName ? "native" : style
        Task { @MainActor [weak self] in
            _ = await self?.applyShellFileRequest(.theme(name: theme, scheme: nil))
            self?.shellHost?.wallpaperPaletteDidChange()
        }
    }

    func setShellPalette(_ palette: ShellTheme?) {
        guard shellPalette != palette else { return }
        shellPalette = palette
        guard let controller, controller.settings.borders.colorSource == .palette else { return }
        controller.surfaceReconciler.noteBorderChanged()
    }
}
