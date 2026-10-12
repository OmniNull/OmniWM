// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct MouseButtonBinding: Equatable, Hashable {
    static let supportedButtons: ClosedRange<Int64> = 2 ... 31
    private static let buttonNamePrefix = "MouseButton"

    let button: Int64
    let modifiers: UInt32

    init?(button: Int64, modifiers: UInt32) {
        guard Self.supportedButtons.contains(button) else { return nil }
        self.button = button
        self.modifiers = modifiers
    }

    var displayString: String {
        KeySymbolMapper.modifierSymbols(modifiers) + "Mouse \(button)"
    }

    var humanReadableString: String {
        let modifierNames = KeySymbolMapper.modifierNames(modifiers)
        let buttonName = Self.buttonNamePrefix + String(button)
        return modifierNames.isEmpty ? buttonName : modifierNames + "+" + buttonName
    }

    static func fromHumanReadable(_ string: String) -> MouseButtonBinding? {
        let parts = string.components(separatedBy: "+").map { $0.replacingOccurrences(of: " ", with: "") }
        guard let buttonPart = parts.last,
              buttonPart.lowercased().hasPrefix(buttonNamePrefix.lowercased()),
              let button = Int64(buttonPart.dropFirst(buttonNamePrefix.count))
        else { return nil }
        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            guard let token = KeySymbolMapper.modifierToken(named: part), token.side == .either else { return nil }
            modifiers |= token.flag
        }
        return MouseButtonBinding(button: button, modifiers: modifiers)
    }
}
