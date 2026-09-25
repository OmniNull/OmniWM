// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class MouseEventHandlerWheelTests: XCTestCase {
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
