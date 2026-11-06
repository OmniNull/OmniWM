// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class SwipeTrackerTests: XCTestCase {
    func testVelocityUsesTrailingWindowAverage() {
        let tracker = SwipeTracker()

        tracker.push(delta: 10, timestamp: 1.000)
        tracker.push(delta: 10, timestamp: 1.025)
        tracker.push(delta: 10, timestamp: 1.050)
        tracker.push(delta: 10, timestamp: 1.075)
        tracker.push(delta: 10, timestamp: 1.100)

        XCTAssertEqual(tracker.velocity(), 40.0 / (1.100 - 1.025))
    }

    func testVelocityDropsToZeroAfterStillTail() {
        let tracker = SwipeTracker()

        tracker.push(delta: 120, timestamp: 1.00)
        tracker.push(delta: 0, timestamp: 1.04)
        tracker.push(delta: 0, timestamp: 1.08)

        XCTAssertEqual(tracker.velocity(), 0)
    }

    func testPartialStillTailDilutesVelocity() {
        let tracker = SwipeTracker()

        tracker.push(delta: 60, timestamp: 1.00)
        tracker.push(delta: 60, timestamp: 1.02)
        tracker.push(delta: 0, timestamp: 1.04)
        tracker.push(delta: 0, timestamp: 1.06)

        XCTAssertGreaterThan(tracker.velocity(), 0)
        XCTAssertLessThan(tracker.velocity(), 6000)
    }

    func testSingleSampleVelocityIsZero() {
        let tracker = SwipeTracker()

        tracker.push(delta: 120, timestamp: 1.00)

        XCTAssertEqual(tracker.velocity(), 0)
    }

    func testOutOfOrderPushIsIgnored() {
        let tracker = SwipeTracker()

        tracker.push(delta: 40, timestamp: 1.00)
        tracker.push(delta: 40, timestamp: 1.04)
        tracker.push(delta: 400, timestamp: 1.03)

        XCTAssertEqual(tracker.position, 80)
        XCTAssertEqual(tracker.velocity(), 80.0 / (1.04 - 1.00))
    }

    func testHistoryLimitIsConfigurable() {
        let wide = SwipeTracker(historyLimit: 0.15)
        let narrow = SwipeTracker()
        for tracker in [wide, narrow] {
            tracker.push(delta: 30, timestamp: 1.00)
            tracker.push(delta: 30, timestamp: 1.10)
            tracker.push(delta: 0, timestamp: 1.14)
        }

        XCTAssertEqual(wide.velocity(), 60 / (1.14 - 1.00))
        XCTAssertEqual(narrow.velocity(), 30 / (1.14 - 1.10))
    }

    func testNonfiniteSamplesAreRejectedWithoutPoisoningState() {
        let tracker = SwipeTracker()

        XCTAssertTrue(tracker.push(delta: 40, timestamp: 1))
        XCTAssertFalse(tracker.push(delta: .nan, timestamp: 1.01))
        XCTAssertFalse(tracker.push(delta: 40, timestamp: .infinity))

        XCTAssertEqual(tracker.position, 40)
        XCTAssertTrue(tracker.velocity().isFinite)
    }
}
