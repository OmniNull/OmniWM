// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import SwiftUI
import XCTest

final class AppRulesSidebarSizingTests: XCTestCase {
    func testDividerMovedTowardTheEditorWidensTheRuleListInBothLayoutDirections() {
        XCTAssertEqual(
            AppRulesSidebarSizing.resized(
                from: 230, dividerOffset: 80, layoutDirection: .leftToRight, availableWidth: 1016
            ),
            310
        )
        XCTAssertEqual(
            AppRulesSidebarSizing.resized(
                from: 230, dividerOffset: -30, layoutDirection: .rightToLeft, availableWidth: 1016
            ),
            260
        )
        XCTAssertEqual(
            AppRulesSidebarSizing.resized(
                from: 230, dividerOffset: 20, layoutDirection: .rightToLeft, availableWidth: 1016
            ),
            210
        )
    }

    func testMaximumGrowsWithTheWindowWhileReservingTheEditorWidth() {
        let wideWindow: CGFloat = 1376
        XCTAssertEqual(AppRulesSidebarSizing.clamped(2000, availableWidth: wideWindow), 969)
        XCTAssertEqual(AppRulesSidebarSizing.clamped(680, availableWidth: wideWindow), 680)
        XCTAssertEqual(AppRulesSidebarSizing.clamped(500, availableWidth: 760), 353)
    }

    func testRuleListNeverShrinksBelowItsMinimum() {
        XCTAssertEqual(AppRulesSidebarSizing.clamped(120, availableWidth: 1016), 200)
        XCTAssertEqual(AppRulesSidebarSizing.clamped(230, availableWidth: 500), 200)
    }
}
