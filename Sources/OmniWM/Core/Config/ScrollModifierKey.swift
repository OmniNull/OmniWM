// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

enum ScrollModifierKey: String, CaseIterable, Codable {
    case optionShift
    case controlShift
    case commandShift
    case controlOptionShift
    case optionCommandShift
    case controlCommandShift
    case controlOptionCommandShift

    var displayName: String {
        switch self {
        case .optionShift: "Option+Shift (⌥⇧)"
        case .controlShift: "Control+Shift (⌃⇧)"
        case .commandShift: "Command+Shift (⌘⇧)"
        case .controlOptionShift: "Control+Option+Shift (⌃⌥⇧)"
        case .optionCommandShift: "Option+Command+Shift (⌥⌘⇧)"
        case .controlCommandShift: "Control+Command+Shift (⌃⌘⇧)"
        case .controlOptionCommandShift: "Control+Option+Command+Shift (⌃⌥⌘⇧)"
        }
    }
}
