// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class TabRailOrderingRegressionTests: XCTestCase {
    func testStableVisibleRailDoesNotReorder() {
        XCTAssertFalse(
            TabRailOrderingPolicy.shouldReorder(
                forceOrdering: false,
                wasOrderedIn: true,
                lastActiveWindowId: 41,
                activeWindowId: 41
            )
        )
    }

    func testForcedHiddenOrChangedActiveTabReordersRail() {
        let cases: [(String, Bool, Bool, Int)] = [
            ("forced", true, true, 41),
            ("hidden", false, false, 41),
            ("activeChanged", false, true, 42)
        ]
        for (label, force, visible, active) in cases {
            XCTAssertTrue(TabRailOrderingPolicy.shouldReorder(
                forceOrdering: force, wasOrderedIn: visible, lastActiveWindowId: 41, activeWindowId: active
            ), label)
        }
    }
}
