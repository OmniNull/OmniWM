// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
@testable import OmniWM
import XCTest

final class PaletteShortcutsTests: XCTestCase {
    private let command = UInt32(cmdKey)
    private let controlOption = UInt32(controlKey | optionKey)
    private let controlOptionShift = UInt32(controlKey | optionKey | shiftKey)
    private let ansiLetters = PaletteShortcuts(previewKeyCode: nil, revealKeyCode: nil)

    private func chord(_ keyCode: Int, _ modifiers: UInt32) -> HotkeyTrigger {
        .chord(KeyBinding(keyCode: UInt32(keyCode), modifiers: modifiers))
    }

    private func hits(_ shortcuts: PaletteShortcuts, _ trigger: HotkeyTrigger) -> [PaletteShortcut] {
        shortcuts.collisions(with: trigger).map(\.shortcut)
    }

    private func notes(_ trigger: HotkeyTrigger) -> [String] {
        ansiLetters.collisions(with: trigger).map(\.note)
    }

    func testCommandDigitChordsCollideWithModeShortcuts() {
        XCTAssertEqual(hits(ansiLetters, chord(kVK_ANSI_1, command)), [.mode(.windows)])
        XCTAssertEqual(hits(ansiLetters, chord(kVK_ANSI_2, command)), [.mode(.menu)])
        XCTAssertEqual(hits(ansiLetters, chord(kVK_ANSI_Keypad6, command)), [.mode(.files)])
        XCTAssertEqual(hits(ansiLetters, chord(kVK_ANSI_7, command)), [])
        XCTAssertEqual(hits(ansiLetters, chord(kVK_ANSI_1, UInt32(optionKey))), [])
        XCTAssertEqual(hits(ansiLetters, chord(kVK_ANSI_1, command | UInt32(shiftKey))), [])
    }

    func testPreviewAndRevealChordsUseCommandOnly() {
        XCTAssertEqual(hits(ansiLetters, chord(kVK_ANSI_Y, command)), [.togglePreview])
        XCTAssertEqual(hits(ansiLetters, chord(kVK_ANSI_R, command)), [.reveal])
        XCTAssertEqual(hits(ansiLetters, chord(kVK_Return, command)), [.reveal])
        XCTAssertEqual(hits(ansiLetters, chord(kVK_ANSI_KeypadEnter, command)), [.reveal])
        XCTAssertEqual(hits(ansiLetters, chord(kVK_ANSI_Y, controlOption)), [])
        XCTAssertEqual(hits(ansiLetters, chord(kVK_Return, controlOption)), [])
    }

    func testMarkChordsCollideOnlyWithControlOptionShift() {
        XCTAssertEqual(hits(ansiLetters, chord(kVK_ANSI_M, controlOptionShift)), [.setMark])
        XCTAssertEqual(hits(ansiLetters, chord(kVK_ANSI_R, controlOptionShift)), [.removeMark])
        XCTAssertEqual(hits(ansiLetters, chord(kVK_ANSI_M, controlOption)), [])
        XCTAssertEqual(hits(ansiLetters, chord(kVK_ANSI_M, command)), [])
    }

    func testSideSpecificGlobalShortcutsCollide() {
        let rightCommandOne = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: command).settingSide(.right)

        XCTAssertEqual(hits(ansiLetters, .chord(rightCommandOne)), [.mode(.windows)])
    }

    func testLetterShortcutsUseTheKeyThatTypesTheLetterAndFallBackToANSI() {
        let qwertz = PaletteShortcuts(previewKeyCode: UInt16(kVK_ANSI_Z), revealKeyCode: nil)

        XCTAssertEqual(hits(qwertz, chord(kVK_ANSI_Z, command)), [.togglePreview])
        XCTAssertEqual(hits(qwertz, chord(kVK_ANSI_Y, command)), [])
        XCTAssertEqual(hits(qwertz, chord(kVK_ANSI_R, command)), [.reveal])
    }

    func testMouseButtonsAndUnassignedShortcutsNeverCollide() throws {
        let button = try XCTUnwrap(MouseButtonBinding(
            button: MouseButtonBinding.supportedButtons.lowerBound,
            modifiers: command
        ))

        XCTAssertEqual(hits(ansiLetters, .mouseButton(button)), [])
        XCTAssertEqual(hits(ansiLetters, .unassigned), [])
    }

    func testCurrentResolvesBothLettersWithoutModifiersInOneLookup() {
        let typedBy: [UniChar: Int] = [
            KeyboardLayoutKeyCode.letter("y"): kVK_ANSI_Z,
            KeyboardLayoutKeyCode.letter("r"): kVK_ANSI_X
        ]
        var requestedModifiers: [UInt32] = []
        let shortcuts = PaletteShortcuts.current { letters, modifiers in
            requestedModifiers.append(modifiers)
            var keyCodes = InlineArray<2, UInt16?>(repeating: nil)
            for index in letters.indices {
                keyCodes[index] = typedBy[letters[index]].map(UInt16.init)
            }
            return keyCodes
        }

        XCTAssertEqual(requestedModifiers, [0])
        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_Z, command)), [.togglePreview])
        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_X, command)), [.reveal])
        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_Y, command)), [])
        XCTAssertEqual(hits(shortcuts, chord(kVK_ANSI_R, command)), [])
    }

    func testCollisionNotesSayWhatThePaletteReservesTheChordFor() {
        XCTAssertEqual(
            notes(chord(kVK_ANSI_1, command)),
            ["While the command palette is open, ⌘1 is reserved for switching to Windows mode."]
        )
        XCTAssertEqual(
            notes(chord(kVK_ANSI_2, command)),
            ["While the command palette is open, ⌘2 is reserved for switching to Menu mode when it is available."]
        )
        XCTAssertEqual(
            notes(chord(kVK_ANSI_Y, command)),
            ["While the command palette is open, ⌘Y is reserved for toggling the file preview in Files mode."]
        )
        XCTAssertEqual(
            notes(chord(kVK_ANSI_R, command)),
            [
                "While the command palette is open, ⌘R is reserved for revealing the selected item in Finder "
                    + "in Launcher and Files modes; in other modes it acts like Return."
            ]
        )
        XCTAssertEqual(
            notes(chord(kVK_ANSI_M, controlOptionShift)),
            ["While the command palette is open, ⌃⌥⇧M is reserved for marking the selected window in Windows mode."]
        )
        XCTAssertEqual(
            notes(chord(kVK_ANSI_R, controlOptionShift)),
            [
                "While the command palette is open, ⌃⌥⇧R is reserved for removing a mark from the selected window "
                    + "in Windows mode."
            ]
        )
    }
}
