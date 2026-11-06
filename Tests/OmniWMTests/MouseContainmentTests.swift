// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class MouseContainmentTests: XCTestCase {
    private func makeMonitor(_ displayId: CGDirectDisplayID, _ name: String, _ frame: CGRect) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name
        )
    }

    private func routing(
        _ displayId: CGDirectDisplayID,
        _ name: String,
        _ column: Int,
        _ row: Int
    ) -> MonitorRoutingSettings {
        MonitorRoutingSettings(monitorName: name, monitorDisplayId: displayId, gridColumn: column, gridRow: row)
    }

    func testStackedPhysicalCrossingWallsWhenGridRoutesHorizontally() {
        let bottom = makeMonitor(1, "Bottom", CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let top = makeMonitor(2, "Top", CGRect(x: 0, y: 1080, width: 1920, height: 1080))
        let monitors = [bottom, top]
        let layout = [routing(1, "Bottom", 0, 0), routing(2, "Top", 1, 0)]

        let upward = MouseContainment(layout: layout, monitors: monitors).evaluate(
            location: CGPoint(x: 960, y: 1600),
            source: bottom,
            destination: top,
            margin: 1
        )
        let downward = MouseContainment(layout: layout, monitors: monitors).evaluate(
            location: CGPoint(x: 960, y: 400),
            source: top,
            destination: bottom,
            margin: 1
        )

        assertWall(upward, CGPoint(x: 960, y: 1078))
        assertWall(downward, CGPoint(x: 960, y: 1082))
    }

    func testGridMatchingPhysicalCrossingAllows() {
        let left = makeMonitor(1, "Left", CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let right = makeMonitor(2, "Right", CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        let monitors = [left, right]
        let layout = [routing(1, "Left", 0, 0), routing(2, "Right", 1, 0)]

        let verdict = MouseContainment(layout: layout, monitors: monitors).evaluate(
            location: CGPoint(x: 1925, y: 500),
            source: left,
            destination: right,
            margin: 1
        )

        XCTAssertEqual(verdict, .allow)
    }

    func testPhysicalCrossingThatSkipsGridNeighborWalls() {
        let left = makeMonitor(1, "Left", CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let middle = makeMonitor(2, "Middle", CGRect(x: 1000, y: 0, width: 1000, height: 1000))
        let right = makeMonitor(3, "Right", CGRect(x: 2000, y: 0, width: 1000, height: 1000))
        let monitors = [left, middle, right]
        let layout = [
            routing(1, "Left", 0, 0),
            routing(2, "Middle", 1, 0),
            routing(3, "Right", 2, 0)
        ]

        let verdict = MouseContainment(layout: layout, monitors: monitors).evaluate(
            location: CGPoint(x: 2500, y: 500),
            source: left,
            destination: right,
            margin: 2
        )

        assertWall(verdict, CGPoint(x: 997, y: 500))
    }

    func testIncompleteDuplicateAndUnreachableLayoutsFailOpen() {
        let source = makeMonitor(1, "Source", CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let destination = makeMonitor(2, "Destination", CGRect(x: 0, y: 1000, width: 1000, height: 1000))
        let monitors = [source, destination]

        XCTAssertEqual(
            MouseContainment(layout: [routing(1, "Source", 0, 0)], monitors: monitors).evaluate(
                location: CGPoint(x: 500, y: 1500),
                source: source,
                destination: destination,
                margin: 2
            ),
            .allow
        )
        XCTAssertEqual(
            MouseContainment(layout: [routing(1, "Source", 0, 0), routing(2, "Destination", 0, 0)], monitors: monitors)
                .evaluate(
                    location: CGPoint(x: 500, y: 1500),
                    source: source,
                    destination: destination,
                    margin: 2
                ),
            .allow
        )
        XCTAssertEqual(
            MouseContainment(layout: [routing(1, "Source", 0, 0), routing(2, "Destination", 1, 1)], monitors: monitors)
                .evaluate(
                    location: CGPoint(x: 500, y: 1500),
                    source: source,
                    destination: destination,
                    margin: 2
                ),
            .allow
        )
    }

    func testZeroCenterDeltaAndSameMonitorAllow() {
        let first = makeMonitor(1, "First", CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let second = makeMonitor(2, "Second", CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let layout = [routing(1, "First", 0, 0), routing(2, "Second", 1, 0)]

        XCTAssertEqual(
            MouseContainment(layout: layout, monitors: [first, second]).evaluate(
                location: CGPoint(x: 500, y: 500),
                source: first,
                destination: first,
                margin: 2
            ),
            .allow
        )
        XCTAssertEqual(
            MouseContainment(layout: layout, monitors: [first, second]).evaluate(
                location: CGPoint(x: 500, y: 500),
                source: first,
                destination: second,
                margin: 2
            ),
            .allow
        )
    }

    func testNegativeOriginCornerOvershootClampsBothAxes() {
        let source = makeMonitor(1, "Source", CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        let destination = makeMonitor(2, "Destination", CGRect(x: -1920, y: 1080, width: 1920, height: 1080))
        let monitors = [source, destination]
        let layout = [routing(1, "Source", 0, 0), routing(2, "Destination", 1, 0)]

        let verdict = MouseContainment(layout: layout, monitors: monitors).evaluate(
            location: CGPoint(x: 600, y: 2500),
            source: source,
            destination: destination,
            margin: 4
        )

        assertWall(verdict, CGPoint(x: -5, y: 1075))
    }

    private func assertWall(
        _ verdict: MouseContainment.Verdict,
        _ expected: CGPoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .wall(clamped) = verdict else {
            XCTFail("Expected wall", file: file, line: line)
            return
        }
        XCTAssertEqual(clamped.x, expected.x, file: file, line: line)
        XCTAssertEqual(clamped.y, expected.y, file: file, line: line)
    }
}
