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

    private func hits(_ shortcuts: PaletteShortcuts, _ trigger: HotkeyTrigger) -> [PaletteShortcut] {
        shortcuts.collisions(with: trigger).map(\.shortcut)
    }

    func testDigitChordsUnderThePaletteModifierCollideWithModeShortcuts() {
        let shortcuts = shortcuts()

        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_1, command)), [.mode(.windows)])
        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_2, command)), [.mode(.menu)])
        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_Keypad6, command)), [.mode(.files)])
        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_7, command)), [])
        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_1, UInt32(optionKey))), [])
        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_1, command | UInt32(shiftKey))), [])
    }

    func testCollisionsFollowTheConfiguredPaletteModifier() throws {
        let shortcuts = shortcuts(try XCTUnwrap(PaletteModifier(carbonMask: controlOption)))

        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_4, controlOption)), [.mode(.commands)])
        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_Y, controlOption)), [.togglePreview])
        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_R, controlOption)), [.reveal])
        XCTAssertEqual(hits(shortcuts, chord(kVK_Return, controlOption)), [.reveal])
        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_KeypadEnter, controlOption)), [.reveal])
        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_4, command)), [])
        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_R, command)), [])
    }

    func testMarkChordsCollideWhateverThePaletteModifier() {
        let shortcuts = shortcuts()

        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_M, controlOptionShift)), [.setMark])
        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_R, controlOptionShift)), [.removeMark])
        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_M, controlOption)), [])
    }

    func testSideSpecificGlobalShortcutsCollide() {
        let rightCommandOne = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: command).settingSide(.right)

        XCTAssertEqual(hits(shortcuts(), .chord(rightCommandOne)), [.mode(.windows)])
    }

    func testLetterShortcutsUseTheKeyThatTypesTheLetter() {
        let qwertz = shortcuts { letter in
            switch letter {
            case "y": UInt32(kVK_ANSI_Z)
            case "r": UInt32(kVK_ANSI_R)
            default: nil
            }
        }

        XCTAssertEqual(hits(qwertz, chord(kVK_ANSI_Z, command)), [.togglePreview])
        XCTAssertEqual(hits(qwertz, chord(kVK_ANSI_Y, command)), [])
    }

    func testMouseButtonsAndUnassignedShortcutsNeverCollide() throws {
        let button = try XCTUnwrap(MouseButtonBinding(button: 3, modifiers: command))

        XCTAssertEqual(hits(shortcuts(), .mouseButton(button)), [])
        XCTAssertEqual(hits(shortcuts(), .unassigned), [])
    }

    func testCollisionNoteNamesThePaletteShortcutThatTakesOver() {
        let shortcuts = shortcuts()

        XCTAssertEqual(
            shortcuts.collisions(with: chord(kVK_ANSI_1, command)).map(\.note),
            ["While the command palette is open, ⌘1 switches to Windows mode instead."]
        )
        XCTAssertEqual(
            shortcuts.collisions(with: chord(kVK_ANSI_M, controlOptionShift)).map(\.note),
            ["While the command palette is open, ⌃⌥⇧M marks the selected window instead."]
        )
    }

    func testChordUsedByTwoPaletteShortcutsReportsBoth() throws {
        let shortcuts = shortcuts(try XCTUnwrap(PaletteModifier(carbonMask: controlOptionShift)))

        XCTAssertEqual(
            shortcuts.collisions(with: chord(kVK_ANSI_R, controlOptionShift)).map(\.shortcut),
            [.reveal, .removeMark]
        )
    }
}
