// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class NiriScrollTrackerTests: XCTestCase {
    func testAccumulateCapsBurstsAndCarriesSubTickRemainder() {
        let cases: [(String, [CGFloat], [Int])] = [
            ("positive", [1500, 5], [127, 0]),
            ("negative", [-1500, -5], [-127, 0]),
            ("repeated", [1500, 1500, 5], [127, 127, 0]),
            ("sub-tick remainder carries", [15, 5], [1, 1]),
            ("below threshold accumulates", [5, 5], [0, 1]),
            ("exact cap leaves no remainder", [1270, 9], [127, 0]),
            ("direction change resets remainder", [5, -5, -5], [0, 0, -1])
        ]
        for (label, inputs, expected) in cases {
            var tracker = NiriScrollTracker(tick: 10)
            XCTAssertEqual(inputs.map { tracker.accumulate($0) }, expected, label)
        }
    }

    func testProductionTickDiscardsWholeTickSurplus() {
        var tracker = NiriScrollTracker(tick: 120)

        XCTAssertEqual(tracker.accumulate(30_000), 127)
        XCTAssertEqual(tracker.accumulate(120), 1)
    }

    func testResetClearsAccumulator() {
        var tracker = NiriScrollTracker(tick: 10)

        XCTAssertEqual(tracker.accumulate(15), 1)
        tracker.reset()
        XCTAssertEqual(tracker.accumulate(5), 0)
        XCTAssertEqual(tracker.accumulate(5), 1)
    }

    func testProductionOverflowKeepsOnlySubTickRemainder() {
        var tracker = NiriScrollTracker(tick: 120)

        XCTAssertEqual(tracker.accumulate(20_000), 127)
        XCTAssertEqual(tracker.accumulator, 80, accuracy: 0.001)
    }
}
