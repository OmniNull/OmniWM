// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
@testable import OmniWM
import XCTest

final class SidedHyperBindingDetectorTests: XCTestCase {
    private func hyperBinding(id: String, side: ModifierSide) -> HotkeyBinding {
        let chord = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: KeySymbolMapper.hyperModifiers)
            .settingSide(side)
        return HotkeyBinding(id: id, command: .focusNavigation(.previous), binding: chord)
    }

    func testFiresForSidedHyperBinding() {
        for (side, label) in [(ModifierSide.left, "Left-side"), (.right, "Right-side")] {
            let issues = SidedHyperBindingDetector.issues(currentBindings: [hyperBinding(id: "a", side: side)])
            XCTAssertEqual(issues.map(\.id), ["hotkey-sided-hyper:a"], label)
            XCTAssertTrue(issues.first?.message.contains(label) ?? false, label)
        }
    }

    func testIgnoresUnsidedHyperBinding() {
        let binding = HotkeyBinding(
            id: "c",
            command: .focusNavigation(.previous),
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: KeySymbolMapper.hyperModifiers)
        )
        XCTAssertTrue(SidedHyperBindingDetector.issues(currentBindings: [binding]).isEmpty)
    }

    func testIgnoresSidedNonHyperBinding() {
        let binding = HotkeyBinding(
            id: "d",
            command: .focusNavigation(.previous),
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(shiftKey)).settingSide(.left)
        )
        XCTAssertTrue(SidedHyperBindingDetector.issues(currentBindings: [binding]).isEmpty)
    }
}
