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

    func publishWallpaperPalette(_ pixels: [UInt32]) async throws -> Bool {
        guard config.themeName == ShellWallpaperPalette.themeName, let writer = wallpaperPalette else { return false }
        if try await writer.publish(pixels, scheme: config.wallpaperScheme) {
            reloadConfig()
        }
        return true
    }

    func refreshWallpaperPalette() {
        wallpaperPalette?.refresh()
    }

    func wallpaperPaletteDidChange() {
        feed?.wallpaper?.update()
    }

    func setWallpaperManager(_ manager: WallpaperManager?) {
        if let previous = resources.wallpaper, previous !== manager, previous.palette === self {
            previous.palette = nil
        }
        resources.wallpaper = manager
        manager?.palette = self
        feed?.setWallpaper(manager)
    }
}

extension ShellWallpaperPaletteWriter {
    static func publish(_ pixels: [UInt32], scheme: ShellWallpaperScheme, to destination: URL) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            performOnWriterQueue {
                continuation.resume(with: Result {
                    try ShellWallpaperPalette.write(
                        ShellWallpaperPalette.theme(pixels: pixels, scheme: scheme), to: destination
                    )
                })
            }
        }
    }
}
