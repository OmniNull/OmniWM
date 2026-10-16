// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

struct SettingsColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
}

enum BorderGradientDirection: String, Codable, CaseIterable, Equatable, Hashable {
    case topLeftToBottomRight
    case topRightToBottomLeft
}

struct BorderGradientColors: Codable, Equatable {
    var start: SettingsColor?
    var end: SettingsColor?
}

struct BorderGradient: Codable, Equatable {
    var enabled: Bool
    var start: SettingsColor
    var end: SettingsColor
    var direction: BorderGradientDirection
    var dark: BorderGradientColors?

    static let `default` = BorderGradient(
        enabled: false,
        start: SettingsColor(red: 0.0, green: 0.4, blue: 1.0, alpha: 1.0),
        end: SettingsColor(red: 0.0, green: 1.0, blue: 0.7, alpha: 1.0),
        direction: .topLeftToBottomRight
    )
}

struct BorderGlow: Codable, Equatable {
    var enabled: Bool
    var radius: Double
    var opacity: Double
    var color: SettingsColor?
    var darkColor: SettingsColor?

    static let `default` = BorderGlow(enabled: false, radius: 8.0, opacity: 0.6)
}
