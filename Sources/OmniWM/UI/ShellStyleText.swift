// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum ShellStyleText {
    static func title(_ profile: String) -> String {
        profile == ShellDefaults.profile ? String(localized: "Default") : paletteTitle(profile)
    }

    static func paletteTitle(_ name: String) -> String {
        switch name {
        case "native": String(localized: "Follow macOS")
        case ShellWallpaperPalette.themeName: String(localized: "Wallpaper Colors")
        case "tonalSpot": String(localized: "Tonal Spot")
        case "fruitSalad": String(localized: "Fruit Salad")
        default: name.replacingOccurrences(of: "-", with: " ").localizedCapitalized
        }
    }

    static func summary(_ profile: String) -> String {
        switch profile {
        case "default": String(localized: "Familiar Mac controls with Focus Ribbon for window navigation.")
        case "lake": String(localized: "A minimal bar and a customizable island for media, calendar, and more.")
        case "celestial": String(localized: "A vertical bar with spacious app and workspace tiles.")
        case "nocturne": String(localized: "A rounded bar with rich status widgets and deep colors.")
        case "wayline": String(localized: "A structured bar with labeled workspaces and quick status controls.")
        case "matrix": String(localized: "A terminal-inspired bar with green accents and a rain shader.")
        case "sakura": String(localized: "A light bar with soft pink accents and a drifting-petal shader.")
        case "vitreus": String(localized: "Liquid glass with a Desk for focus sessions and tasks.")
        default: String(localized: "A custom style you added.")
        }
    }
}
