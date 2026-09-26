// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class HiddenBarFallbackIconTests: XCTestCase {
    private func monitor(
        frame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 875)
    ) -> Monitor {
        Monitor(
            id: Monitor.ID(displayId: 1),
            displayId: 1,
            frame: frame,
            visibleFrame: visibleFrame,
            hasNotch: false,
            notchRange: nil,
            name: "Test"
        )
    }

    func testIconFrameSitsLeadingOfIsland() {
        let frame = HiddenBarFallbackIconController.iconFrame(
            monitor: monitor(),
            barVisible: true,
            barFrame: CGRect(x: 570, y: 851, width: 300, height: 24)
        )
        XCTAssertEqual(frame, CGRect(x: 538, y: 851, width: 24, height: 24))
    }

    func testIconFrameClampsToMonitorLeftEdge() {
        let frame = HiddenBarFallbackIconController.iconFrame(
            monitor: monitor(),
            barVisible: true,
            barFrame: CGRect(x: 10, y: 851, width: 300, height: 24)
        )
        XCTAssertEqual(frame.minX, 8)
        XCTAssertEqual(frame.minY, 851)
    }

    func testBottomFallbackStaysBesideShortBarsAndAboveWideBars() {
        let bounds = CGRect(x: -800, y: -600, width: 800, height: 600)
        let visible = CGRect(x: -752, y: -560, width: 752, height: 532)
        let screen = monitor(frame: bounds, visibleFrame: visible)
        for width: CGFloat in [300, visible.width, 1000] {
            let bar = CGRect(x: visible.midX - width / 2, y: visible.minY, width: width, height: 32)
            let icon = HiddenBarFallbackIconController.iconFrame(
                monitor: screen, barVisible: true, barFrame: bar, position: .bottom
            )
            XCTAssertTrue(visible.contains(icon))
            XCTAssertFalse(icon.intersects(bar))
            if width == 300 {
                XCTAssertEqual(icon.maxX + HiddenBarFallbackIconController.gap, bar.minX)
                XCTAssertEqual(icon.minY, bar.minY)
            } else {
                XCTAssertEqual(icon.minY, bar.maxY + HiddenBarFallbackIconController.gap)
            }
        }
    }

    func testIconFrameFallsBackBelowMenuBarWhenBarHidden() {
        let frame = HiddenBarFallbackIconController.iconFrame(
            monitor: monitor(),
            barVisible: false,
            barFrame: CGRect(x: 570, y: 851, width: 300, height: 24)
        )
        XCTAssertEqual(frame, CGRect(x: 708, y: 847, width: 24, height: 24))
    }

    func testIconFrameFallsBackWhenBarFrameUnknown() {
        let frame = HiddenBarFallbackIconController.iconFrame(
            monitor: monitor(),
            barVisible: true,
            barFrame: nil
        )
        XCTAssertEqual(frame, CGRect(x: 708, y: 847, width: 24, height: 24))
    }

    @MainActor
    func testAccessibilityPressRoutesAsPlainLeftClick() {
        let button = HiddenBarFallbackIconButton(title: "", target: nil, action: nil)
        let identifier = ObjectIdentifier(button)
        var routed = false
        button.onClick = { event, anchor in
            routed = event.type == .leftMouseUp && ObjectIdentifier(anchor) == identifier
        }

        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertTrue(routed)
    }
}
