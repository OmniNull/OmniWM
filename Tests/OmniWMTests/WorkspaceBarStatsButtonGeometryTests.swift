// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class WorkspaceBarStatsButtonGeometryTests: XCTestCase {
    func testStatsButtonAnchorUsesCenterForEitherOrientation() {
        let buttonFrame = CGRect(x: 628, y: 950, width: 22, height: 20)

        let anchor = WorkspaceBarGeometry.statsButtonAnchor(buttonFrame: buttonFrame)

        XCTAssertEqual(anchor, CGPoint(x: 639, y: 960))
    }

    func testStatsButtonAnchorTracksMovedInlineButton() {
        let first = WorkspaceBarGeometry.statsButtonAnchor(
            buttonFrame: CGRect(x: 628, y: 950, width: 22, height: 20)
        )
        let moved = WorkspaceBarGeometry.statsButtonAnchor(
            buttonFrame: CGRect(x: 700, y: 926, width: 22, height: 20)
        )

        XCTAssertEqual(moved.x - first.x, 72)
        XCTAssertEqual(moved.y, 936)
    }
}
