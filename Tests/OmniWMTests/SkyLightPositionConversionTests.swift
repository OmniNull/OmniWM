// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class SkyLightPositionConversionTests: XCTestCase {
    func testWindowServerRectangleRoundTrip() throws {
        let frame = try Self.testFrame()
        let windowServerFrame = ScreenCoordinateSpace.toWindowServer(rect: frame)
        let roundTrippedFrame = ScreenCoordinateSpace.toAppKit(rect: windowServerFrame)

        assertRect(roundTrippedFrame, frame)
    }

    func testSkyLightPositionUsesConvertedRectangleOrigin() throws {
        let frame = try Self.testFrame()
        let positions = AXManager.windowServerPositions([
            SkyLightPositionTarget(token: WindowToken(pid: 7, windowId: 42), frame: frame)
        ])
        let position = try XCTUnwrap(positions.first)
        let convertedFrame = ScreenCoordinateSpace.toWindowServer(rect: frame)
        let pointConvertedOrigin = ScreenCoordinateSpace.toWindowServer(point: frame.origin)

        XCTAssertEqual(position.windowId, 42)
        assertPoint(position.origin, convertedFrame.origin)
        XCTAssertEqual(
            pointConvertedOrigin.y - position.origin.y,
            convertedFrame.height
        )
        XCTAssertNotEqual(position.origin.y, pointConvertedOrigin.y)
    }

    private static func testFrame() throws -> CGRect {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        return CGRect(
            x: screen.frame.minX + screen.frame.width * 0.2,
            y: screen.frame.minY + screen.frame.height * 0.2,
            width: screen.frame.width * 0.3,
            height: screen.frame.height * 0.25
        )
    }

    private func assertPoint(
        _ actual: CGPoint,
        _ expected: CGPoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let span = max(ScreenCoordinateSpace.globalFrame.maxX, ScreenCoordinateSpace.globalFrame.maxY)
        XCTAssertEqual(
            actual.x,
            expected.x,
            accuracy: CGFloat.rounding(operations: 10, at: span),
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.y,
            expected.y,
            accuracy: CGFloat.rounding(operations: 10, at: span),
            file: file,
            line: line
        )
    }

    private func assertRect(
        _ actual: CGRect,
        _ expected: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertPoint(actual.origin, expected.origin, file: file, line: line)
        XCTAssertEqual(
            actual.width,
            expected.width,
            accuracy: CGFloat.rounding(operations: 2, at: expected.width),
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.height,
            expected.height,
            accuracy: CGFloat.rounding(operations: 2, at: expected.height),
            file: file,
            line: line
        )
    }
}
