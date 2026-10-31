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

    func canStartNaturalDrag(windowId: Int) -> Bool {
        guard let controller,
              controller.settings.niri.naturalWindowDrag,
              let entry = controller.workspaceManager.entry(forWindowId: windowId),
              entry.mode == .tiling
        else { return false }
        return controller.workspaceManager.activeLayoutKind(for: entry.workspaceId) == .niri
    }

    nonisolated static func modifierFlagsMatch(_ modifiers: CGEventFlags, required: CGEventFlags) -> Bool {
        modifiers.intersection(Self.relevantModifierFlags) == required
    }
}
