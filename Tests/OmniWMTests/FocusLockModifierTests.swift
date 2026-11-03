// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import CoreGraphics
@testable import OmniWM
import XCTest

final class FocusLockModifierTests: XCTestCase {
    private let leftOption = CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICELALTKEYMASK)
    private let rightOption = CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICERALTKEYMASK)
    private let leftCommand = CGEventFlags.maskCommand.rawValue | UInt64(NX_DEVICELCMDKEYMASK)
    private let leftControl = CGEventFlags.maskControl.rawValue | UInt64(NX_DEVICELCTLKEYMASK)
    private let rightShift = CGEventFlags.maskShift.rawValue | UInt64(NX_DEVICERSHIFTKEYMASK)

    func testOffNeverHeld() {
        XCTAssertFalse(FocusLockModifier.off.isHeld(inRawFlags: 0))
        XCTAssertFalse(FocusLockModifier.off.isHeld(inRawFlags: leftOption))
        XCTAssertFalse(FocusLockModifier.off.isHeld(inRawFlags: rightOption))
    }

    func testNoModifierHeldIsNeverDetected() {
        for modifier in FocusLockModifier.allCases {
            XCTAssertFalse(modifier.isHeld(inRawFlags: 0), "\(modifier) should not be held with no flags")
        }
    }

    func testEitherSideMatchesLeftRightAndBoth() {
        XCTAssertTrue(FocusLockModifier.option.isHeld(inRawFlags: leftOption))
        XCTAssertTrue(FocusLockModifier.option.isHeld(inRawFlags: rightOption))
        XCTAssertTrue(FocusLockModifier.option.isHeld(inRawFlags: leftOption | rightOption))
    }

    func testSidedOptionRequiresItsOwnSideOnly() {
        let cases: [(modifier: FocusLockModifier, own: UInt64, other: UInt64)] = [
            (.leftOption, leftOption, rightOption),
            (.rightOption, rightOption, leftOption)
        ]
        for (modifier, own, other) in cases {
            XCTAssertTrue(modifier.isHeld(inRawFlags: own), "\(modifier)")
            XCTAssertFalse(modifier.isHeld(inRawFlags: other), "\(modifier)")
            XCTAssertFalse(modifier.isHeld(inRawFlags: own | other), "\(modifier)")
        }
    }

    func testDifferentModifierFamiliesAreIndependent() {
        XCTAssertTrue(FocusLockModifier.leftCommand.isHeld(inRawFlags: leftCommand))
        XCTAssertTrue(FocusLockModifier.leftControl.isHeld(inRawFlags: leftControl))
        XCTAssertTrue(FocusLockModifier.rightShift.isHeld(inRawFlags: rightShift))

        XCTAssertFalse(FocusLockModifier.leftOption.isHeld(inRawFlags: leftCommand))
        XCTAssertFalse(FocusLockModifier.leftCommand.isHeld(inRawFlags: leftOption))
    }

    func testOtherModifiersPresentDoNotBlockMatch() {
        XCTAssertTrue(FocusLockModifier.leftOption.isHeld(inRawFlags: leftOption | leftCommand))
        XCTAssertTrue(FocusLockModifier.option.isHeld(inRawFlags: leftOption | rightShift))
    }

    func testRawValueRoundTrip() {
        for modifier in FocusLockModifier.allCases {
            XCTAssertEqual(FocusLockModifier(rawValue: modifier.rawValue), modifier)
        }
        XCTAssertEqual(FocusLockModifier.leftOption.rawValue, "leftOption")
        XCTAssertEqual(FocusLockModifier.off.rawValue, "off")
    }

    func testInvalidRawValueIsNil() {
        XCTAssertNil(FocusLockModifier(rawValue: "garbage"))
        XCTAssertEqual(FocusLockModifier(rawValue: "garbage") ?? .off, .off)
    }
}
