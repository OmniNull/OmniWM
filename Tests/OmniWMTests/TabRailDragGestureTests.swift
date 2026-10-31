// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class TabRailDragGestureTests: XCTestCase {
    func testADragPastTheThresholdStartsOnce() {
        var gesture = TabRailDragGesture(threshold: 10)
        gesture.press(visualIndex: 2, at: CGPoint(x: 100, y: 100))

        XCTAssertNil(gesture.drag(to: CGPoint(x: 106, y: 104)))
        XCTAssertEqual(
            gesture.drag(to: CGPoint(x: 112, y: 100)),
            .init(visualIndex: 2, pressPoint: CGPoint(x: 100, y: 100))
        )
        XCTAssertNil(gesture.drag(to: CGPoint(x: 140, y: 90)))
    }

    func testAPressWithoutADragIsOnlyAClick() {
        var gesture = TabRailDragGesture(threshold: 10)
        gesture.press(visualIndex: 0, at: CGPoint(x: 10, y: 10))

        XCTAssertNil(gesture.drag(to: CGPoint(x: 15, y: 12)))
        gesture.release()
        XCTAssertNil(gesture.drag(to: CGPoint(x: 50, y: 50)))
    }

    func testNothingHappensWithoutAPress() {
        var gesture = TabRailDragGesture()

        XCTAssertNil(gesture.drag(to: CGPoint(x: 500, y: 500)))
    }
}
