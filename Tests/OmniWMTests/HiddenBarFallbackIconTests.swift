// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class HiddenBarFallbackIconTests: XCTestCase {
    private let mainDisplay = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func monitor(
        displayId: CGDirectDisplayID = 1,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect? = nil
    ) -> Monitor {
        Monitor(
            id: Monitor.ID(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: visibleFrame ?? CGRect(
                x: frame.minX,
                y: frame.minY,
                width: frame.width,
                height: frame.height - 25
            ),
            hasNotch: false,
            notchRange: nil,
            name: "Test"
        )
    }

    private func requestedBarFrame(
        on display: Monitor,
        fittingWidth: CGFloat = 300,
        xOffset: Double = 0,
        yOffset: Double = 0
    ) -> CGRect {
        let resolved = ResolvedBarSettings(
            enabled: true,
            showLabels: true,
            showFloatingWindows: true,
            deduplicateAppIcons: false,
            hideEmptyWorkspaces: false,
            excludedBundleIDs: [],
            reserveLayoutSpace: false,
            notchMode: .off,
            notchActiveZoneWidth: 300,
            systemStatsButton: false,
            position: .overlappingMenuBar,
            windowLevel: .normal,
            height: 24,
            backgroundOpacity: 0.5,
            inactiveIconOpacity: nil,
            transparentBackground: false,
            solidBlackBackground: false,
            showItemBackgrounds: true,
            showAccentHighlights: true,
            xOffset: xOffset,
            yOffset: yOffset,
            accentColor: nil,
            textColor: nil
        )
        let geometry = WorkspaceBarGeometry.resolve(monitor: display, resolved: resolved, isVisible: true)
        return geometry.frame(fittingWidth: fittingWidth, monitor: display, resolved: resolved)
    }

    private func iconFrame(on display: Monitor, barFrame: CGRect) -> CGRect {
        HiddenBarFallbackIconController.iconFrame(monitor: display, barVisible: true, barFrame: barFrame)
    }

    private func assertFullyContained(
        _ frame: CGRect,
        in display: Monitor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, display.frame.minX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, display.frame.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, display.frame.maxX, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, display.frame.maxY, file: file, line: line)
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

    func testIconFrameKeepsReportedNegativeOffsetOnMonitor() {
        let display = monitor()
        let barFrame = requestedBarFrame(on: display, yOffset: -2000)
        XCTAssertEqual(barFrame, CGRect(x: 570, y: -1125, width: 300, height: 24))
        XCTAssertFalse(display.frame.contains(barFrame))

        let frame = iconFrame(on: display, barFrame: barFrame)

        XCTAssertEqual(frame, CGRect(x: 538, y: 0, width: 24, height: 24))
        assertFullyContained(frame, in: display)
        XCTAssertEqual(frame.minY, display.frame.minY)
    }

    func testIconFrameClampsAboveRightAndMultipleEdges() {
        let display = monitor()

        let above = requestedBarFrame(on: display, yOffset: 2000)
        XCTAssertEqual(above, CGRect(x: 570, y: 2875, width: 300, height: 24))
        let aboveIcon = iconFrame(on: display, barFrame: above)
        XCTAssertEqual(aboveIcon, CGRect(x: 538, y: 876, width: 24, height: 24))
        assertFullyContained(aboveIcon, in: display)

        let beyondRight = requestedBarFrame(on: display, xOffset: 4000)
        XCTAssertEqual(beyondRight, CGRect(x: 4570, y: 875, width: 300, height: 24))
        let rightIcon = iconFrame(on: display, barFrame: beyondRight)
        XCTAssertEqual(rightIcon, CGRect(x: 1416, y: 875, width: 24, height: 24))
        assertFullyContained(rightIcon, in: display)

        let beyondEdges = requestedBarFrame(on: display, xOffset: 4000, yOffset: -2000)
        XCTAssertEqual(beyondEdges, CGRect(x: 4570, y: -1125, width: 300, height: 24))
        let edgeIcon = iconFrame(on: display, barFrame: beyondEdges)
        XCTAssertEqual(edgeIcon, CGRect(x: 1416, y: 0, width: 24, height: 24))
        assertFullyContained(edgeIcon, in: display)

        let partial = CGRect(x: 1452, y: 890, width: 300, height: 24)
        XCTAssertTrue(display.frame.contains(CGPoint(x: partial.minX - 32, y: partial.minY)))
        let partialIcon = iconFrame(on: display, barFrame: partial)
        XCTAssertEqual(partialIcon, CGRect(x: 1416, y: 876, width: 24, height: 24))
        assertFullyContained(partialIcon, in: display)
    }

    func testIconFramePreservesOnScreenPlacementNearEdges() {
        let display = monitor()
        let barFrame = CGRect(x: 1000, y: 851, width: 300, height: 24)
        XCTAssertEqual(
            iconFrame(on: display, barFrame: barFrame),
            CGRect(x: 968, y: 851, width: 24, height: 24)
        )

        let flush = CGRect(x: 1448, y: 876, width: 300, height: 24)
        XCTAssertEqual(
            iconFrame(on: display, barFrame: flush),
            CGRect(x: 1416, y: 876, width: 24, height: 24)
        )
    }

    func testIconFrameUsesMonitorWithNegativeOrigin() {
        let display = monitor(
            displayId: 2,
            frame: CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        )
        let onScreen = requestedBarFrame(on: display)
        XCTAssertEqual(onScreen, CGRect(x: -1110, y: -25, width: 300, height: 24))
        let onScreenIcon = iconFrame(on: display, barFrame: onScreen)
        XCTAssertEqual(onScreenIcon, CGRect(x: -1142, y: -25, width: 24, height: 24))
        assertFullyContained(onScreenIcon, in: display)
        XCTAssertFalse(mainDisplay.contains(onScreenIcon))

        let below = requestedBarFrame(on: display, yOffset: -2000)
        XCTAssertEqual(below, CGRect(x: -1110, y: -2025, width: 300, height: 24))
        let belowIcon = iconFrame(on: display, barFrame: below)
        XCTAssertEqual(belowIcon, CGRect(x: -1142, y: -1080, width: 24, height: 24))
        assertFullyContained(belowIcon, in: display)
        XCTAssertEqual(belowIcon.minY, display.frame.minY)
        XCTAssertFalse(mainDisplay.contains(belowIcon))

        let shiftedOntoMain = requestedBarFrame(on: display, xOffset: 1500, yOffset: 100)
        XCTAssertEqual(shiftedOntoMain, CGRect(x: 390, y: 75, width: 300, height: 24))
        XCTAssertTrue(mainDisplay.contains(shiftedOntoMain))
        let shiftedIcon = iconFrame(on: display, barFrame: shiftedOntoMain)
        XCTAssertEqual(shiftedIcon, CGRect(x: -24, y: -24, width: 24, height: 24))
        assertFullyContained(shiftedIcon, in: display)
        XCTAssertFalse(mainDisplay.contains(shiftedIcon))

        let nearLeft = CGRect(x: display.frame.minX + 10, y: -25, width: 300, height: 24)
        let leftIcon = iconFrame(on: display, barFrame: nearLeft)
        XCTAssertEqual(leftIcon.minX, display.frame.minX + 8)
        XCTAssertEqual(leftIcon.minY, nearLeft.minY)
        assertFullyContained(leftIcon, in: display)
    }

    func testIconFrameUsesVerticallyStackedMonitor() {
        let upper = monitor(
            displayId: 3,
            frame: CGRect(x: 0, y: 900, width: 1440, height: 900)
        )
        let onScreen = requestedBarFrame(on: upper)
        XCTAssertEqual(onScreen, CGRect(x: 570, y: 1775, width: 300, height: 24))
        let onScreenIcon = iconFrame(on: upper, barFrame: onScreen)
        XCTAssertEqual(onScreenIcon, CGRect(x: 538, y: 1775, width: 24, height: 24))
        assertFullyContained(onScreenIcon, in: upper)
        XCTAssertFalse(mainDisplay.contains(onScreenIcon))

        let onMain = requestedBarFrame(on: upper, yOffset: -1000)
        XCTAssertEqual(onMain, CGRect(x: 570, y: 775, width: 300, height: 24))
        XCTAssertTrue(mainDisplay.contains(onMain))
        let pulledBack = iconFrame(on: upper, barFrame: onMain)
        XCTAssertEqual(pulledBack, CGRect(x: 538, y: 900, width: 24, height: 24))
        assertFullyContained(pulledBack, in: upper)
        XCTAssertFalse(mainDisplay.contains(pulledBack))

        let above = requestedBarFrame(on: upper, yOffset: 2000)
        XCTAssertEqual(above, CGRect(x: 570, y: 3775, width: 300, height: 24))
        let aboveIcon = iconFrame(on: upper, barFrame: above)
        XCTAssertEqual(aboveIcon, CGRect(x: 538, y: 1776, width: 24, height: 24))
        assertFullyContained(aboveIcon, in: upper)
        XCTAssertFalse(mainDisplay.contains(aboveIcon))
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
