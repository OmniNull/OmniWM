// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class StopWindowGeometryTests: XCTestCase {
    private let visibleFrame = CGRect(x: -1200, y: 80, width: 1000, height: 700)
    private let windowSize = CGSize(width: 360, height: 240)

    func testTopLeftClampPreservesSizeAndKeepsTitleEdgeOnscreen() throws {
        let outside = CGPoint(x: visibleFrame.maxX + windowSize.width, y: visibleFrame.maxY + windowSize.height)
        let current = CGRect(origin: outside, size: windowSize)
        let restored = try XCTUnwrap(StopWindowGeometry.destination(
            for: current, in: visibleFrame, placement: .topLeft(outside)
        ))

        XCTAssertEqual(restored.size, windowSize)
        XCTAssertEqual(restored.maxX, visibleFrame.maxX)
        XCTAssertEqual(restored.maxY, visibleFrame.maxY)
    }

    func testOversizedWindowKeepsItsTopLeftVisibleWithoutResizing() throws {
        let oversized = CGSize(
            width: visibleFrame.width + windowSize.width,
            height: visibleFrame.height + windowSize.height
        )
        let current = CGRect(origin: visibleFrame.origin, size: oversized)
        let restored = try XCTUnwrap(StopWindowGeometry.destination(for: current, in: visibleFrame, placement: nil))

        XCTAssertEqual(restored.size, oversized)
        XCTAssertEqual(restored.minX, visibleFrame.minX)
        XCTAssertEqual(restored.maxY, visibleFrame.maxY)
    }

    func testFloatingNormalizedOriginUsesTheCurrentNativeSize() throws {
        let normalized = CGPoint(x: 0.25, y: 0.75)
        let current = CGRect(origin: .zero, size: windowSize)
        let restored = try XCTUnwrap(StopWindowGeometry.destination(
            for: current, in: visibleFrame, placement: .floatingNormalizedOrigin(normalized)
        ))

        XCTAssertEqual(restored.origin, CGPoint(
            x: visibleFrame.minX + (visibleFrame.width - windowSize.width) * normalized.x,
            y: visibleFrame.minY + (visibleFrame.height - windowSize.height) * normalized.y
        ))
        XCTAssertEqual(restored.size, windowSize)
    }

    func testMissingMonitorDoesNotInventDestination() {
        XCTAssertNil(StopWindowGeometry.destination(
            for: CGRect(origin: .zero, size: windowSize), in: nil, placement: .floatingOrigin(visibleFrame.origin)
        ))
    }
}
