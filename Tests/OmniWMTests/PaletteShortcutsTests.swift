// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
@testable import OmniWM
import XCTest

final class PaletteShortcutsTests: XCTestCase {
    private let command = UInt32(cmdKey)
    private let controlOption = UInt32(controlKey | optionKey)
    private let controlOptionShift = UInt32(controlKey | optionKey | shiftKey)

    private func shortcuts(
        _ modifier: PaletteModifier = .default,
        keyCodeForLetter: @escaping (Character) -> UInt32? = { _ in nil }
    ) -> PaletteShortcuts {
        PaletteShortcuts(modifier: modifier, keyCodeForLetter: keyCodeForLetter)
    }

    private func chord(_ keyCode: Int, _ modifiers: UInt32) -> HotkeyTrigger {
        .chord(KeyBinding(keyCode: UInt32(keyCode), modifiers: modifiers))
    }

    func testDigitChordsUnderThePaletteModifierCollideWithModeShortcuts() {
        let shortcuts = shortcuts()

        XCTAssertEqual(shortcuts.collision(with: chord(kVK_ANSI_1, command))?.shortcut, .mode(.windows))
        XCTAssertEqual(shortcuts.collision(with: chord(kVK_ANSI_2, command))?.shortcut, .mode(.menu))
        XCTAssertEqual(shortcuts.collision(with: chord(kVK_ANSI_Keypad6, command))?.shortcut, .mode(.files))
        XCTAssertNil(shortcuts.collision(with: chord(kVK_ANSI_7, command)))
        XCTAssertNil(shortcuts.collision(with: chord(kVK_ANSI_1, UInt32(optionKey))))
        XCTAssertNil(shortcuts.collision(with: chord(kVK_ANSI_1, command | UInt32(shiftKey))))
    }

    func testCollisionsFollowTheConfiguredPaletteModifier() throws {
        let shortcuts = shortcuts(try XCTUnwrap(PaletteModifier(carbonMask: controlOption)))

        XCTAssertEqual(shortcuts.collision(with: chord(kVK_ANSI_4, controlOption))?.shortcut, .mode(.commands))
        XCTAssertEqual(shortcuts.collision(with: chord(kVK_ANSI_Y, controlOption))?.shortcut, .togglePreview)
        XCTAssertEqual(shortcuts.collision(with: chord(kVK_ANSI_R, controlOption))?.shortcut, .reveal)
        XCTAssertEqual(shortcuts.collision(with: chord(kVK_Return, controlOption))?.shortcut, .reveal)
        XCTAssertEqual(shortcuts.collision(with: chord(kVK_ANSI_KeypadEnter, controlOption))?.shortcut, .reveal)
        XCTAssertNil(shortcuts.collision(with: chord(kVK_ANSI_4, command)))
        XCTAssertNil(shortcuts.collision(with: chord(kVK_ANSI_R, command)))
    }

    func testMarkChordsCollideWhateverThePaletteModifier() {
        let shortcuts = shortcuts()

        XCTAssertEqual(shortcuts.collision(with: chord(kVK_ANSI_M, controlOptionShift))?.shortcut, .setMark)
        XCTAssertEqual(shortcuts.collision(with: chord(kVK_ANSI_R, controlOptionShift))?.shortcut, .removeMark)
        XCTAssertNil(shortcuts.collision(with: chord(kVK_ANSI_M, controlOption)))
    }

    func testSideSpecificGlobalShortcutsCollide() {
        let rightCommandOne = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: command).settingSide(.right)

        XCTAssertEqual(shortcuts().collision(with: .chord(rightCommandOne))?.shortcut, .mode(.windows))
    }

    func testLetterShortcutsUseTheKeyThatTypesTheLetter() {
        let qwertz = shortcuts { letter in
            switch letter {
            case "y": UInt32(kVK_ANSI_Z)
            case "r": UInt32(kVK_ANSI_R)
            default: nil
            }
        }

        XCTAssertEqual(qwertz.collision(with: chord(kVK_ANSI_Z, command))?.shortcut, .togglePreview)
        XCTAssertNil(qwertz.collision(with: chord(kVK_ANSI_Y, command)))
    }

    func testMouseButtonsAndUnassignedShortcutsNeverCollide() throws {
        let button = try XCTUnwrap(MouseButtonBinding(button: 3, modifiers: command))

        XCTAssertNil(shortcuts().collision(with: .mouseButton(button)))
        XCTAssertNil(shortcuts().collision(with: .unassigned))
    }

    func testCollisionNoteNamesThePaletteShortcutThatTakesOver() throws {
        let shortcuts = shortcuts()

        XCTAssertEqual(
            try XCTUnwrap(shortcuts.collision(with: chord(kVK_ANSI_1, command))).note,
            "While the command palette is open, ⌘1 switches to Windows mode instead."
        )
        XCTAssertEqual(
            try XCTUnwrap(shortcuts.collision(with: chord(kVK_ANSI_M, controlOptionShift))).note,
            "While the command palette is open, ⌃⌥⇧M marks the selected window instead."
        )
    }
}
