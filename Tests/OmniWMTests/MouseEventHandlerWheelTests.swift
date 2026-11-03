// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class MouseEventHandlerWheelTests: XCTestCase {
    func testMouseWheelSensitivityAdvancesSmoothInputWithLessMovement() throws {
        var baseline = NiriScrollTracker(tick: niriWheelScrollTickAmount)
        var faster = NiriScrollTracker(tick: niriWheelScrollTickAmount)
        let defaultSensitivity = try XCTUnwrap(SettingsExport.Gestures.defaults().mouseWheelSensitivity)
        let sensitivity = 10.0
        let delta = niriWheelScrollTickAmount / CGFloat(sensitivity)

        XCTAssertEqual(baseline.accumulate(MouseEventHandler.scaledWheelAxisDelta(
            delta, isContinuous: true, sensitivity: defaultSensitivity
        )), 0)
        XCTAssertEqual(faster.accumulate(MouseEventHandler.scaledWheelAxisDelta(
            delta, isContinuous: true, sensitivity: sensitivity
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
        let sensitivity = 10.0
        let smallDelta = -niriWheelScrollTickAmount / CGFloat(sensitivity) / 4
        let delta = MouseEventHandler.scaledWheelAxisDelta(smallDelta, isContinuous: true, sensitivity: sensitivity)
        XCTAssertEqual(tracker.accumulate(delta), 0)
        XCTAssertEqual(tracker.accumulate(delta), 0)
        XCTAssertEqual(tracker.accumulate(delta), 0)
        XCTAssertEqual(tracker.accumulate(delta), -1)
        XCTAssertEqual(tracker.accumulator, 0)
    }

    func testDefaultMouseWheelSensitivityPreservesSmoothInput() throws {
        let defaultSensitivity = try XCTUnwrap(SettingsExport.Gestures.defaults().mouseWheelSensitivity)
        let delta = -niriWheelScrollTickAmount / 10
        XCTAssertEqual(MouseEventHandler.scaledWheelAxisDelta(
            delta, isContinuous: true, sensitivity: defaultSensitivity
        ), delta)
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
        let largeDiscreteDelta = -niriWheelScrollTickAmount * 10
        let continuousDelta: CGFloat = 10
        XCTAssertEqual(
            MouseEventHandler.resolvedWheelAxisDelta(
                pointDelta: 1, fixedPointDelta: 0, isContinuous: false
            ),
            niriWheelScrollTickAmount
        )
        XCTAssertEqual(
            MouseEventHandler.resolvedWheelAxisDelta(
                pointDelta: largeDiscreteDelta, fixedPointDelta: 0, isContinuous: false
            ),
            -niriWheelScrollTickAmount
        )
        XCTAssertEqual(
            MouseEventHandler.resolvedWheelAxisDelta(
                pointDelta: continuousDelta, fixedPointDelta: 0, isContinuous: true
            ),
            continuousDelta
        )
        XCTAssertEqual(
            MouseEventHandler.resolvedWheelAxisDelta(
                pointDelta: 0, fixedPointDelta: -1, isContinuous: false
            ),
            -niriWheelScrollTickAmount
        )
        XCTAssertEqual(
            MouseEventHandler.resolvedWheelAxisDelta(
                pointDelta: .leastNonzeroMagnitude, fixedPointDelta: 1, isContinuous: false
            ),
            niriWheelScrollTickAmount
        )
        XCTAssertEqual(
            MouseEventHandler.resolvedWheelAxisDelta(
                pointDelta: 0, fixedPointDelta: 0, isContinuous: false
            ),
            0
        )
    }
}
