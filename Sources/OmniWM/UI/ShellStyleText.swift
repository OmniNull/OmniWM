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
        profile == ShellDefaults.profile
            ? String(localized: "Familiar Mac controls with Focus Ribbon for window navigation.")
            : String(localized: "A custom style you added.")
    }
}

extension ShellStyle {
    var title: String {
        manifest?.title ?? ShellStyleText.title(name)
    }

    var summary: String {
        manifest?.summary ?? ShellStyleText.summary(name)
    }
}

extension ShellConfigurationCoordinator {
    func styleTitle(_ profile: String) -> String {
        style(profile).title
    }

    func styleSummary(_ profile: String) -> String {
        style(profile).summary
    }
}
