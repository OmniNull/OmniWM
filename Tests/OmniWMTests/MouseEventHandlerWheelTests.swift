// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class MouseEventHandlerWheelTests: XCTestCase {
    func testMouseWheelSensitivityAdvancesSmoothInputWithLessMovement() {
        var baseline = NiriScrollTracker(tick: niriWheelScrollTickAmount)
        var faster = NiriScrollTracker(tick: niriWheelScrollTickAmount)

        XCTAssertEqual(baseline.accumulate(MouseEventHandler.scaledWheelAxisDelta(
            12, isContinuous: true, sensitivity: 1
        )), 0)
        XCTAssertEqual(faster.accumulate(MouseEventHandler.scaledWheelAxisDelta(
            12, isContinuous: true, sensitivity: 10
        )), 1)
    }

    func testMouseWheelSensitivityPreservesDiscreteWheelSteps() {
        for sign: CGFloat in [-1, 1] {
            let normalized = MouseEventHandler.resolvedWheelAxisDelta(
                pointDelta: sign, fixedPointDelta: 0, isContinuous: false
            )
            var tracker = NiriScrollTracker(tick: niriWheelScrollTickAmount)
            XCTAssertEqual(tracker.accumulate(MouseEventHandler.scaledWheelAxisDelta(
                normalized, isContinuous: false, sensitivity: 10
            )), Int(sign))
        }
    }

    func testMouseWheelSensitivityPreservesDirectionAndAccumulatesSmallSteps() {
        var tracker = NiriScrollTracker(tick: niriWheelScrollTickAmount)
        let delta = MouseEventHandler.scaledWheelAxisDelta(-4, isContinuous: true, sensitivity: 10)
        XCTAssertEqual(tracker.accumulate(delta), 0)
        XCTAssertEqual(tracker.accumulate(delta), 0)
        XCTAssertEqual(tracker.accumulate(delta), -1)
        XCTAssertEqual(tracker.accumulator, 0)
    }

    func testDefaultMouseWheelSensitivityPreservesSmoothInput() {
        XCTAssertEqual(MouseEventHandler.scaledWheelAxisDelta(
            -12, isContinuous: true, sensitivity: 1
        ), -12)
    }

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
