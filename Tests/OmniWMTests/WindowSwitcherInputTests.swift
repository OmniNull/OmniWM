// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
import CoreGraphics
@testable import OmniWM
import XCTest

final class WindowSwitcherInputTests: XCTestCase {
    func testHoldCycleAndReleaseCommitsOnceWithoutLeakingTabKeyUp() {
        var input = WindowSwitcherInput()
        XCTAssertEqual(key(&input, kVK_Tab).action, .begin(reverse: false))
        XCTAssertTrue(key(&input, kVK_Tab, type: .keyUp).consumed)
        XCTAssertEqual(key(&input, kVK_Tab).action, .cycle(reverse: false))
        XCTAssertEqual(key(&input, kVK_Command, type: .flagsChanged, flags: []).action, .commit)
        XCTAssertTrue(key(&input, kVK_Tab, type: .keyUp, flags: []).consumed)
        XCTAssertNil(key(&input, kVK_Command, type: .flagsChanged, flags: []).action)
        XCTAssertFalse(input.isActive)
    }

    func testShiftReversesAndReleasingShiftDoesNotCommit() {
        var input = WindowSwitcherInput()
        XCTAssertEqual(key(&input, kVK_Tab, flags: [.maskCommand, .maskShift]).action, .begin(reverse: true))
        XCTAssertNil(key(&input, kVK_Shift, type: .flagsChanged).action)
        XCTAssertTrue(input.isActive)
        XCTAssertEqual(key(&input, kVK_Tab, flags: [.maskCommand, .maskShift]).action, .cycle(reverse: true))
    }

    func testEscapeCancelsAndCommandReleaseDoesNotSelect() {
        var input = WindowSwitcherInput()
        _ = key(&input, kVK_Tab)
        XCTAssertEqual(key(&input, kVK_Escape).action, .cancel)
        XCTAssertNil(key(&input, kVK_Command, type: .flagsChanged, flags: []).action)
        XCTAssertTrue(key(&input, kVK_Escape, type: .keyUp).consumed)
    }

    func testScopeShortcutNeverLeaksCommandWAndDoesNotRepeat() {
        var input = WindowSwitcherInput()
        _ = key(&input, kVK_Tab)
        XCTAssertEqual(key(&input, kVK_ANSI_W).action, .toggleScope)
        let repeated = key(&input, kVK_ANSI_W, isRepeat: true)
        XCTAssertTrue(repeated.consumed)
        XCTAssertNil(repeated.action)
        XCTAssertTrue(key(&input, kVK_ANSI_W, type: .keyUp).consumed)
    }

    func testOtherApplicationShortcutsAreSuppressedOnlyDuringSession() {
        var input = WindowSwitcherInput()
        XCTAssertFalse(key(&input, kVK_ANSI_Q).consumed)
        _ = key(&input, kVK_Tab)
        XCTAssertTrue(key(&input, kVK_ANSI_Q).consumed)
        input.cancel(generation: input.generation)
        XCTAssertTrue(key(&input, kVK_ANSI_Q, type: .keyUp).consumed)
        XCTAssertFalse(key(&input, kVK_ANSI_Q).consumed)
    }

    func testDisabledAndDifferentModifiersPassThrough() {
        var input = WindowSwitcherInput()
        XCTAssertFalse(key(&input, kVK_Tab, canBegin: false).consumed)
        XCTAssertFalse(key(&input, kVK_Tab, flags: []).consumed)
        XCTAssertFalse(key(&input, kVK_Tab, flags: [.maskAlternate]).consumed)
        XCTAssertFalse(key(&input, kVK_Tab, flags: [.maskCommand, .maskControl]).consumed)
        XCTAssertFalse(key(&input, kVK_Tab, isRepeat: true).consumed)
    }

    func testDelayedDismissCannotCancelNewKeyboardSession() {
        var input = WindowSwitcherInput()
        _ = key(&input, kVK_Tab)
        let previousGeneration = input.generation
        _ = key(&input, kVK_Tab, type: .keyUp)
        _ = key(&input, kVK_Command, type: .flagsChanged, flags: [])
        _ = key(&input, kVK_Tab)
        input.cancel(generation: previousGeneration)
        XCTAssertTrue(input.isActive)
        XCTAssertEqual(key(&input, kVK_Command, type: .flagsChanged, flags: []).action, .commit)
    }

    func testResetAfterTapInterruptionAllowsNewSession() {
        var input = WindowSwitcherInput()
        _ = key(&input, kVK_Tab)
        input.reset()
        XCTAssertNil(key(&input, kVK_Command, type: .flagsChanged, flags: []).action)
        XCTAssertEqual(key(&input, kVK_Tab).action, .begin(reverse: false))
    }

    private func key(
        _ input: inout WindowSwitcherInput,
        _ keyCode: Int,
        type: CGEventType = .keyDown,
        flags: CGEventFlags = [.maskCommand],
        isRepeat: Bool = false,
        canBegin: Bool = true
    ) -> WindowSwitcherInput.Decision {
        input.handle(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat, canBegin: canBegin)
    }
}
