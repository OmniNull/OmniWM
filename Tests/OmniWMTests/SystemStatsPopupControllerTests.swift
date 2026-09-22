// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class SystemStatsPopupControllerTests: XCTestCase {
    private let size = CGSize(width: 360, height: 420)
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 950)

    func testPopupFrameHangsBelowAnchorCentered() {
        let frame = PopupAttachment(anchor: CGPoint(x: 756, y: 900)).frame(size: size, visibleFrame: screen)

        XCTAssertEqual(frame.midX, 756)
        XCTAssertEqual(frame.maxY, 896)
        XCTAssertEqual(frame.size, size)
    }

    func testPopupFrameClampsAtLeftAndRightEdges() {
        let left = PopupAttachment(anchor: CGPoint(x: 10, y: 900)).frame(size: size, visibleFrame: screen)
        XCTAssertEqual(left.minX, 8)

        let right = PopupAttachment(anchor: CGPoint(x: 1508, y: 900)).frame(size: size, visibleFrame: screen)
        XCTAssertEqual(right.maxX, screen.maxX - 8)
    }

    func testPopupFrameClampsAtBottomEdge() {
        let frame = PopupAttachment(anchor: CGPoint(x: 756, y: 100)).frame(size: size, visibleFrame: screen)

        XCTAssertEqual(frame.minY, 8)
    }

    @MainActor
    func testTargetMonitorPrefersPointerThenMainThenAnyWithAnchor() {
        let pointer = makeMonitor(displayId: 1)
        let main = makeMonitor(displayId: 2)
        let other = makeMonitor(displayId: 3)
        let monitors = [pointer, main, other]

        XCTAssertEqual(
            SystemStatsPopupController.targetMonitor(
                pointer: pointer,
                main: main,
                monitors: monitors
            ) { _ in true }?.id,
            pointer.id
        )
        XCTAssertEqual(
            SystemStatsPopupController.targetMonitor(
                pointer: pointer,
                main: main,
                monitors: monitors
            ) { $0 != pointer.id }?.id,
            main.id
        )
        XCTAssertEqual(
            SystemStatsPopupController.targetMonitor(
                pointer: pointer,
                main: main,
                monitors: monitors
            ) { $0 == other.id }?.id,
            other.id
        )
        XCTAssertNil(
            SystemStatsPopupController.targetMonitor(
                pointer: nil,
                main: nil,
                monitors: monitors
            ) { _ in false }
        )
    }

    private func makeMonitor(displayId: CGDirectDisplayID) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            hasNotch: false,
            name: "Monitor \(displayId)"
        )
    }
}
