// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellWidgetHost: WallpaperPaletteTarget {
    var wallpaperThemeURL: URL {
        shellDirectory.appendingPathComponent("themes/\(ShellWallpaperPalette.themeName).toml")
    }

    var wallpaperPaletteState: WallpaperPaletteState {
        WallpaperPaletteState(
            active: config.themeName == ShellWallpaperPalette.themeName,
            scheme: config.wallpaperScheme
        )
    }

    func publishWallpaperPalette(_ pixels: [UInt32]) -> Bool {
        guard config.themeName == ShellWallpaperPalette.themeName else { return false }
        let text = ShellWallpaperPalette.theme(pixels: pixels, scheme: config.wallpaperScheme)
        do {
            let changed = try wallpaperPalette?.publish(text)
                ?? ShellWallpaperPaletteWriter.publish(text, to: wallpaperThemeURL)
            guard changed else { return true }
        } catch {
            Log.shell.error("Failed to write the wallpaper palette: \(error.localizedDescription)")
            return false
        }
        reloadConfig()
        return true
    }

    func wallpaperPaletteDidChange() {
        feed?.wallpaper?.update()
    }
}
