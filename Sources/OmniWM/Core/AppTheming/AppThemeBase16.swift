// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum AppThemeBase16 {
    static let slots = (0 ..< 16).map { String(format: "base%02X", $0) }

    static func colors(roles: [ShellRole: AppThemeColor], ansi: [AppThemeColor]) -> [String: AppThemeColor] {
        let background = (roles[.background] ?? ansi[0]).opaque
        let lightens = AppThemeColor.white.contrast(background) >= AppThemeColor.black.contrast(background)
        let orange = AppThemeANSI.readable(
            AppThemeColor(ansi[1].rgba.mixed(with: ansi[3].rgba, 0.5)),
            on: background,
            lightens: lightens
        ) ?? ansi[3]
        let grounds = [
            background,
            (roles[.surface] ?? background).opaque,
            (roles[.elevatedSurface] ?? roles[.surface] ?? background).opaque,
            ansi[8], ansi[7], ansi[15], ansi[15], ansi[15]
        ]
        let hues = [ansi[1], orange, ansi[3], ansi[2], ansi[6], ansi[4], ansi[5], ansi[9]]
        return Dictionary(uniqueKeysWithValues: zip(slots, grounds + hues))
    }
}

enum AppThemeNeovim {
    static let guideURL = URL(string: "https://omniwm.app/features/app-theming/#neovim")!
    static let pluginLine = #"{ "RRethy/base16-nvim" },"#
    static let setupLine = #"local ok, omniwm = pcall(require, "omniwm") if ok then omniwm.setup() end"#
}
