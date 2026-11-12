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

    func publishWallpaperPalette(_ pixels: [UInt32]) async -> Bool {
        guard config.themeName == ShellWallpaperPalette.themeName, let writer = wallpaperPalette else { return false }
        let text = ShellWallpaperPalette.theme(pixels: pixels, scheme: config.wallpaperScheme)
        do {
            guard try await writer.publish(text) else { return true }
        } catch {
            Log.shell.error("Failed to write the wallpaper palette: \(error.localizedDescription)")
            return false
        }
        reloadConfig()
        return true
    }

    func refreshWallpaperPalette() {
        wallpaperPalette?.refresh()
    }

    func wallpaperPaletteDidChange() {
        feed?.wallpaper?.update()
    }
}

extension ShellWallpaperPaletteWriter {
    static func publish(_ text: String, to destination: URL) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            performOnWriterQueue {
                continuation.resume(with: Result { try ShellWallpaperPalette.write(text, to: destination) })
            }
        }
    }
}
