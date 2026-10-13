// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class HoverParkedStripTests: XCTestCase {
    private let monitorFrame = CGRect(x: 0, y: 0, width: 2056, height: 1329)

    private func horizontalFrame(overlap: CGFloat) -> CGRect {
        CGRect(x: monitorFrame.maxX - overlap, y: 0, width: 700, height: 1329)
    }

    private func verticalFrame(overlap: CGFloat) -> CGRect {
        CGRect(x: 0, y: monitorFrame.maxY - overlap, width: 2056, height: 700)
    }

    private func isStrip(
        _ frame: CGRect,
        orientation: Monitor.Orientation = .horizontal,
        scale: CGFloat = 2
    ) -> Bool {
        NiriHoverParkedStrip.isParkedStrip(
            frame: frame,
            monitorFrame: monitorFrame,
            orientation: orientation,
            scale: scale
        )
    }

    func testOnePointOverlapIsParkedStrip() {
        XCTAssertTrue(isStrip(horizontalFrame(overlap: 1)))
    }

    func testZeroOverlapIsParkedStrip() {
        XCTAssertTrue(isStrip(horizontalFrame(overlap: 0)))
    }

    func testFrameBeyondMonitorEdgeIsParkedStrip() {
        XCTAssertTrue(isStrip(CGRect(x: monitorFrame.maxX + 40, y: 0, width: 700, height: 1329)))
    }

    func testFrameBeyondLeadingEdgeIsParkedStrip() {
        XCTAssertTrue(isStrip(CGRect(x: -699, y: 0, width: 700, height: 1329)))
    }

    func testSubPointOverlapIsParkedStrip() {
        XCTAssertTrue(isStrip(horizontalFrame(overlap: 0.9)))
    }

    func testTwoPointOverlapIsNotParkedStrip() {
        XCTAssertFalse(isStrip(horizontalFrame(overlap: 2)))
    }

    func testFullyInsideMonitorIsNotParkedStrip() {
        XCTAssertFalse(isStrip(CGRect(x: 100, y: 0, width: 700, height: 1329)))
    }

    func testVerticalOnePointOverlapIsParkedStrip() {
        XCTAssertTrue(isStrip(verticalFrame(overlap: 1), orientation: .vertical))
    }

    func testVerticalTwoPointOverlapIsNotParkedStrip() {
        XCTAssertFalse(isStrip(verticalFrame(overlap: 2), orientation: .vertical))
    }

    func testVerticalOrientationIgnoresHorizontalOverlap() {
        XCTAssertFalse(isStrip(horizontalFrame(overlap: 1), orientation: .vertical))
    }

    func testScaleToleranceBoundary() {
        let scale: CGFloat = 2
        let boundary = 1 + 0.5 / scale
        XCTAssertTrue(isStrip(horizontalFrame(overlap: boundary), scale: scale))
        XCTAssertFalse(isStrip(horizontalFrame(overlap: boundary + 0.01), scale: scale))
    }

    func testScaleBelowOneUsesUnitScaleTolerance() {
        let boundary: CGFloat = 1.5
        XCTAssertTrue(isStrip(horizontalFrame(overlap: boundary), scale: 0.5))
        XCTAssertFalse(isStrip(horizontalFrame(overlap: boundary + 0.01), scale: 0.5))
    }
}
