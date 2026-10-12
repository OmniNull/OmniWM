// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class MouseEventHandlerWheelTests: XCTestCase {
    func testScrollModifierChoicesMatchOnlyTheirExactModifierCombination() {
        let choices: [(ScrollModifierKey, CGEventFlags)] = [
            (.optionShift, [.maskAlternate, .maskShift]),
            (.controlShift, [.maskControl, .maskShift]),
            (.commandShift, [.maskCommand, .maskShift]),
            (.controlOptionShift, [.maskControl, .maskAlternate, .maskShift]),
            (.optionCommandShift, [.maskAlternate, .maskCommand, .maskShift]),
            (.controlCommandShift, [.maskControl, .maskCommand, .maskShift]),
            (.controlOptionCommandShift, [.maskControl, .maskAlternate, .maskCommand, .maskShift])
        ]
        XCTAssertEqual(Set(ScrollModifierKey.allCases), Set(choices.map(\.0)))
        let modifierFlags: [CGEventFlags] = [.maskAlternate, .maskControl, .maskCommand, .maskShift]
        for (choice, expectedFlags) in choices {
            XCTAssertEqual(choice.cgEventFlag, expectedFlags, choice.rawValue)
            for combination in 0 ..< 16 {
                var flags: CGEventFlags = []
                for (index, flag) in modifierFlags.enumerated() where combination & (1 << index) != 0 {
                    flags.insert(flag)
                }
                XCTAssertEqual(
                    MouseEventHandler.mouseWheelModifiersMatch(flags, required: choice.cgEventFlag),
                    flags == expectedFlags,
                    "\(choice.rawValue), flags: \(flags.rawValue)"
                )
            }
            XCTAssertTrue(MouseEventHandler.mouseWheelModifiersMatch(
                expectedFlags.union(.maskAlphaShift), required: choice.cgEventFlag
            ))
        }
    }

    func testDiscreteWheelAxisDeltaNormalizesToOneTick() {
        XCTAssertEqual(
            MouseEventHandler.resolvedWheelAxisDelta(
                pointDelta: 1, fixedPointDelta: 0, isContinuous: false
            ),
            120
        )
        XCTAssertEqual(
            MouseEventHandler.resolvedWheelAxisDelta(
                pointDelta: -1200, fixedPointDelta: 0, isContinuous: false
            ),
            -120
        )
        XCTAssertEqual(
            MouseEventHandler.resolvedWheelAxisDelta(
                pointDelta: 10, fixedPointDelta: 0, isContinuous: true
            ),
            10
        )
        XCTAssertEqual(
            MouseEventHandler.resolvedWheelAxisDelta(
                pointDelta: 0, fixedPointDelta: -1, isContinuous: false
            ),
            -120
        )
        XCTAssertEqual(
            MouseEventHandler.resolvedWheelAxisDelta(
                pointDelta: 0.0005, fixedPointDelta: 1, isContinuous: false
            ),
            120
        )
        XCTAssertEqual(
            MouseEventHandler.resolvedWheelAxisDelta(
                pointDelta: 0, fixedPointDelta: 0, isContinuous: false
            ),
            0
        )
    }
}
