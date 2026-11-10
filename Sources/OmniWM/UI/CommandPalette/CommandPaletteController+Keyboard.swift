// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon

@MainActor
extension CommandPaletteController {
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if [UInt16(36), 48, 49, 51, 53, 76, 123, 124, 125, 126].contains(event.keyCode),
           let inputClient = presentation.panel?.firstResponder as? NSTextInputClient,
           inputClient.hasMarkedText()
        {
            return false
        }
        let relevantModifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])

        if isUnifiedSearch {
            return handleUnifiedKeyDown(event, relevantModifiers: relevantModifiers)
        }

        if handleMarkKeyDown(event, relevantModifiers: relevantModifiers) { return true }

        if handleLauncherKeyDown(event, relevantModifiers: relevantModifiers) {
            return true
        }

        if let targetMode = CommandPalettePresentation.modeNavigationTarget(
            currentMode: selectedMode,
            isMenuModeAvailable: isMenuModeAvailable,
            keyCode: event.keyCode,
            relevantModifiers: relevantModifiers,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) {
            selectedMode = targetMode
            return true
        }

        switch event.keyCode {
        case 53:
            dismiss(reason: .cancel)
            return true
        case 126:
            guard !isLauncherMode else { return false }
            moveSelection(by: -1)
            return true
        case 125:
            guard !isLauncherMode else { return false }
            moveSelection(by: 1)
            return true
        default:
            guard let trigger = Self.selectionTrigger(
                forKeyCode: event.keyCode,
                modifierFlags: relevantModifiers
            ) else {
                return false
            }
            selectCurrent(trigger: trigger)
            return true
        }
    }

    private func handleUnifiedKeyDown(_ event: NSEvent, relevantModifiers: NSEvent.ModifierFlags) -> Bool {
        if case .window? = selectedItemID, handleMarkKeyDown(event, relevantModifiers: relevantModifiers) {
            return true
        }
        if handleLauncherRevealKey(event, modifiers: relevantModifiers) { return true }
        if let index = CommandPalettePresentation.topHitIndex(
            keyCode: event.keyCode,
            relevantModifiers: relevantModifiers,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) {
            openUnifiedTopHit(at: index)
            return true
        }
        if event.keyCode == UInt16(kVK_Tab), relevantModifiers.isEmpty || relevantModifiers == .shift {
            jumpUnifiedSection(by: relevantModifiers == .shift ? -1 : 1)
            return true
        }
        if CommandPalettePresentation.modeNavigationTarget(
            currentMode: selectedMode,
            isMenuModeAvailable: isMenuModeAvailable,
            keyCode: event.keyCode,
            relevantModifiers: relevantModifiers,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) != nil {
            return true
        }

        switch event.keyCode {
        case 53:
            dismiss(reason: .cancel)
            return true
        case 126:
            moveSelection(by: -1)
            return true
        case 125:
            moveSelection(by: 1)
            return true
        default:
            guard let trigger = Self.selectionTrigger(
                forKeyCode: event.keyCode,
                modifierFlags: relevantModifiers
            ) else {
                return false
            }
            selectCurrent(trigger: trigger)
            return true
        }
    }

    private func handleMarkKeyDown(_ event: NSEvent, relevantModifiers: NSEvent.ModifierFlags) -> Bool {
        guard isUnifiedSearch || selectedMode == .windows,
              let markAction = CommandPalettePresentation.markAction(
                  forKeyCode: event.keyCode,
                  relevantModifiers: relevantModifiers
              )
        else { return false }
        guard isExpanded else {
            expandResults()
            actionFeedbackText = String(localized: "Select a window row before changing its marks.")
            return true
        }
        switch markAction {
        case .set:
            setMarkOnSelectedWindow()
        case .remove:
            removeMarkFromSelectedWindow()
        }
        return true
    }

    private static func selectionTrigger(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> CommandPaletteSelectionTrigger? {
        switch keyCode {
        case 36,
             76:
            return modifierFlags == .shift ? .alternate : .primary
        default:
            return nil
        }
    }
}
