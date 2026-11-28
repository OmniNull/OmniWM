// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class HiddenWindowRevealTests: XCTestCase {
    private let monitor = HiddenPlacementMonitorContext(
        id: Monitor.ID(displayId: 900_100),
        frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130)
    )

    func testEffectiveRevealIsOnePointOrZero() {
        XCTAssertEqual(HiddenWindowPlacementResolver.effectiveReveal(baseReveal: 1.0), 1.0)
        XCTAssertEqual(HiddenWindowPlacementResolver.effectiveReveal(baseReveal: 0), 0)
    }

    func testHiddenWindowKeepsAtLeastOnePointOnScreen() {
        let size = CGSize(width: 230, height: 408)
        let origin = HiddenWindowPlacementResolver(
            monitor: monitor,
            monitors: [monitor]
        ).placement(
            for: size,
            requestedEdge: .minimum,
            orthogonalOrigin: 268,
            baseReveal: 1.0,
            orientation: .horizontal
        ).origin

        let onScreenWidth = (origin.x + size.width) - monitor.visibleFrame.minX
        XCTAssertGreaterThanOrEqual(onScreenWidth, 1.0)
        XCTAssertEqual(origin.x.rounded(), origin.x)
    }

    func testTransientPlacementKeepsAtLeastOnePointOnScreen() {
        let size = CGSize(width: 893, height: 1130)
        let placement = HiddenWindowPlacementResolver(
            monitor: monitor,
            monitors: [monitor]
        ).placement(
            for: size,
            requestedEdge: .minimum,
            orthogonalOrigin: 0,
            baseReveal: 1.0,
            orientation: .horizontal
        )

        let onScreenWidth = (placement.origin.x + size.width) - monitor.visibleFrame.minX
        XCTAssertGreaterThanOrEqual(onScreenWidth, 1.0)
    }

    func testMaximumEdgeKeepsAtLeastOnePointOnScreen() {
        let size = CGSize(width: 893, height: 1130)
        let placement = HiddenWindowPlacementResolver(
            monitor: monitor,
            monitors: [monitor]
        ).placement(
            for: size,
            requestedEdge: .maximum,
            orthogonalOrigin: 0,
            baseReveal: 1.0,
            orientation: .horizontal
        )

        let onScreenWidth = monitor.visibleFrame.maxX - placement.origin.x
        XCTAssertGreaterThanOrEqual(onScreenWidth, 1.0)
    }

    func testWindowTallerThanItsDisplayIsNotParkedOnTheDisplayBelow() {
        let laptop = makeMonitor(displayId: 900_101, frame: CGRect(x: 0, y: 0, width: 1710, height: 1112))
        let below = makeMonitor(displayId: 900_102, frame: CGRect(x: -1069, y: 1112, width: 3840, height: 2160))
        let size = CGSize(width: 1916, height: below.frame.height - 88)

        let frame = parkedFrame(size: size, from: below.frame.minY + 58, on: laptop, among: [laptop, below])

        XCTAssertTrue(frame.intersection(below.frame).isEmpty, "\(frame)")
        XCTAssertEqual(frame.minX, laptop.visibleFrame.maxX - 1)
    }

    func testWindowTallerThanItsDisplayIsNotParkedOnTheDisplayAbove() {
        let above = makeMonitor(displayId: 900_103, frame: CGRect(x: -1069, y: 0, width: 3840, height: 2160))
        let laptop = makeMonitor(
            displayId: 900_104,
            frame: CGRect(x: 0, y: above.frame.maxY, width: 1710, height: 1112)
        )
        let size = CGSize(width: 1916, height: above.frame.height - 88)

        let frame = parkedFrame(size: size, from: above.frame.minY + 58, on: laptop, among: [above, laptop])

        XCTAssertTrue(frame.intersection(above.frame).isEmpty, "\(frame)")
        XCTAssertEqual(frame.minX, laptop.visibleFrame.maxX - 1)
    }

    func testWindowFromAnotherDisplayIsParkedWithinItsOwnDisplaysBand() {
        let laptop = makeMonitor(displayId: 900_105, frame: CGRect(x: 0, y: 0, width: 1710, height: 1112))
        let below = makeMonitor(displayId: 900_106, frame: CGRect(x: -1069, y: 1112, width: 3840, height: 2160))
        let size = CGSize(width: 843, height: 1000)

        let frame = parkedFrame(size: size, from: below.frame.minY + 58, on: laptop, among: [laptop, below])

        XCTAssertTrue(frame.intersection(below.frame).isEmpty, "\(frame)")
        XCTAssertGreaterThanOrEqual(frame.minY, laptop.frame.minY)
        XCTAssertLessThanOrEqual(frame.maxY, laptop.frame.maxY)
    }

    func testWindowCarryingAnotherDisplaysPositionStillTouchesItsOwnDisplay() {
        let laptop = makeMonitor(displayId: 900_107, frame: CGRect(x: 0, y: 0, width: 1710, height: 1112))
        let below = makeMonitor(displayId: 900_108, frame: CGRect(x: -1069, y: 1112, width: 3840, height: 2160))
        let size = CGSize(width: 843, height: 1000)

        let frame = parkedFrame(
            size: size,
            from: laptop.frame.minY + 66,
            on: below,
            among: [laptop, below],
            edge: .minimum
        )

        XCTAssertFalse(frame.intersection(below.frame).isEmpty, "\(frame)")
        XCTAssertTrue(frame.intersection(laptop.frame).isEmpty, "\(frame)")
        XCTAssertEqual(frame.maxX, below.visibleFrame.minX + 1)
    }

    private func makeMonitor(displayId: UInt32, frame: CGRect) -> HiddenPlacementMonitorContext {
        HiddenPlacementMonitorContext(id: Monitor.ID(displayId: displayId), frame: frame, visibleFrame: frame)
    }

    private func parkedFrame(
        size: CGSize,
        from orthogonalOrigin: CGFloat,
        on monitor: HiddenPlacementMonitorContext,
        among monitors: [HiddenPlacementMonitorContext],
        edge: AxisHideEdge = .maximum
    ) -> CGRect {
        HiddenWindowPlacementResolver(monitor: monitor, monitors: monitors).placement(
            for: size,
            requestedEdge: edge,
            orthogonalOrigin: orthogonalOrigin,
            baseReveal: 1.0,
            orientation: .horizontal
        ).frame(for: size)
    }
}
