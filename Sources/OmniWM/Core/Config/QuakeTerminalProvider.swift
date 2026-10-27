// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

enum QuakeTerminalProvider: String, CaseIterable, Codable {
    case ghostty
    case kitty
    case warp

    var displayName: String {
        switch self {
        case .ghostty: "Ghostty"
        case .kitty: "Kitty"
        case .warp: "Warp"
        }
    }
}
