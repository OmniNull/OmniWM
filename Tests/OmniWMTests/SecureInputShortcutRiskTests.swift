// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
@testable import OmniWM
import XCTest

final class SecureInputShortcutRiskTests: XCTestCase {
    private let shiftedCharacters: [UInt32: String] = [
        UInt32(kVK_ANSI_1): "!",
        UInt32(kVK_ANSI_Equal): "+",
        UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_Period): ">",
        UInt32(kVK_ANSI_Grave): "~",
        UInt32(kVK_ANSI_Keypad1): "1",
        UInt32(kVK_LeftArrow): "\u{1C}",
        UInt32(kVK_Return): "\r",
        UInt32(kVK_Tab): "\t",
        UInt32(kVK_Space): " "
    ]
    private let option = UInt32(optionKey)
    private let shift = UInt32(shiftKey)
    private let hyper = HyperKeyModifiers.default.carbonMask

    func testOptionOnlyCharacterChordsArePaused() {
        XCTAssertTrue(isPaused(chord(kVK_ANSI_1, option)))
        XCTAssertTrue(isPaused(chord(kVK_ANSI_Equal, option)))
        XCTAssertTrue(isPaused(chord(kVK_ANSI_J, option | shift)))
        XCTAssertTrue(isPaused(chord(kVK_ANSI_Period, option)))
        XCTAssertTrue(isPaused(chord(kVK_ANSI_Grave, option)))
        XCTAssertTrue(isPaused(chord(kVK_ANSI_J, 0)))
    }

    func testControlCommandAndNonCharacterKeysKeepWorking() {
        XCTAssertFalse(isPaused(chord(kVK_ANSI_Equal, option | UInt32(controlKey))))
        XCTAssertFalse(isPaused(chord(kVK_ANSI_J, option | UInt32(cmdKey))))
        XCTAssertFalse(isPaused(chord(kVK_LeftArrow, option)))
        XCTAssertFalse(isPaused(chord(kVK_Return, option)))
        XCTAssertFalse(isPaused(chord(kVK_Tab, option)))
        XCTAssertFalse(isPaused(chord(kVK_Space, option)))
        XCTAssertFalse(isPaused(chord(kVK_ANSI_Keypad1, option)))
        XCTAssertFalse(isPaused(chord(kVK_F13, option)))
    }

    func testSideSpecificChordsArePausedBecauseTheTapIsBlind() {
        let rightOption = KeyBinding(
            keyCode: UInt32(kVK_ANSI_J),
            modifiers: option,
            sidedModifiers: SidedModifiers(right: option)
        )
        let rightCommand = KeyBinding(
            keyCode: UInt32(kVK_ANSI_J),
            modifiers: UInt32(cmdKey),
            sidedModifiers: SidedModifiers(right: UInt32(cmdKey))
        )
        XCTAssertTrue(isPaused(.chord(rightOption)))
        XCTAssertTrue(isPaused(.chord(rightCommand)))
    }

    func testHyperChordsArePausedOnlyWhenAHyperTriggerSynthesizesThem() {
        let hyperJ = chord(kVK_ANSI_J, hyper)
        XCTAssertTrue(isPaused(hyperJ, hyperTriggerConfigured: true))
        XCTAssertFalse(isPaused(hyperJ, hyperTriggerConfigured: false))
    }

    func testMouseUnassignedAndUntranslatableTriggersAreNotFlagged() throws {
        let mouse = try XCTUnwrap(MouseButtonBinding(button: 3, modifiers: option))
        XCTAssertFalse(isPaused(.mouseButton(mouse)))
        XCTAssertFalse(isPaused(.unassigned))
        XCTAssertFalse(isPaused(chord(kVK_ANSI_Q, option)))
    }

    private func chord(_ keyCode: Int, _ modifiers: UInt32) -> HotkeyTrigger {
        .chord(KeyBinding(keyCode: UInt32(keyCode), modifiers: modifiers))
    }

    private func isPaused(_ trigger: HotkeyTrigger, hyperTriggerConfigured: Bool = false) -> Bool {
        SecureInputShortcutRisk.isPaused(
            trigger,
            hyperTriggerConfigured: hyperTriggerConfigured,
            hyperModifiers: hyper,
            shiftedCharacters: { self.shiftedCharacters[$0] }
        )
    }
}
