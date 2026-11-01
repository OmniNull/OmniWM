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

    func syncNaturalDragTapFilter() {
        let snapshot = inputTapThread.filterSnapshot
        guard controller?.settings.niri.naturalWindowDrag == true
            || snapshot.naturalWindowDrag
            || snapshot.naturalDragModifier != nil
        else { return }
        syncTapFilterSnapshot()
    }

    nonisolated static func isUnassignedDragModifier(
        _ modifiers: CGEventFlags,
        moveModifier: CGEventFlags?,
        naturalDragModifier: CGEventFlags?
    ) -> Bool {
        !modifiers.isDisjoint(with: Self.relevantModifierFlags)
            && !mouseMoveModifiersMatch(modifiers, required: moveModifier)
            && !mouseMoveModifiersMatch(modifiers, required: naturalDragModifier)
    }

    func canStartNaturalDrag(windowId: Int?, at location: CGPoint) -> Bool {
        if let windowId {
            return canStartNaturalDrag(windowId: windowId)
        }
        guard let workspaceId = workspaceIdForPointer(at: location),
              let token = geometricFocusIntentCandidate(at: location, workspaceId: workspaceId)
        else { return false }
        return canStartNaturalDrag(windowId: token.windowId)
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
