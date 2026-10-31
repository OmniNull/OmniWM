// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    nonisolated static let relevantModifierFlags: CGEventFlags = [
        .maskAlternate,
        .maskShift,
        .maskControl,
        .maskCommand
    ]

    nonisolated static func mouseMoveModifiersMatch(_ modifiers: CGEventFlags, required: CGEventFlags?) -> Bool {
        guard let required, !required.isEmpty else { return false }
        let relevantModifiers = modifiers.intersection(Self.relevantModifierFlags)
        return relevantModifiers == required || relevantModifiers == required.union(.maskShift)
    }

    nonisolated static func naturalDragPassThroughFlags(
        _ modifiers: CGEventFlags,
        naturalDragModifier: CGEventFlags?
    ) -> CGEventFlags {
        guard mouseMoveModifiersMatch(modifiers, required: naturalDragModifier) else { return modifiers }
        return modifiers.subtracting(.maskAlternate)
    }

    nonisolated static func modifierFlagsMatch(_ modifiers: CGEventFlags, required: CGEventFlags) -> Bool {
        modifiers.intersection(Self.relevantModifierFlags) == required
    }
}
