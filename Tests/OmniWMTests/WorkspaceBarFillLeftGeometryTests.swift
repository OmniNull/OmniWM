// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class WorkspaceBarFillLeftGeometryTests: XCTestCase {
    private func makeMonitor(
        frame: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleTop: CGFloat = 950,
        hasNotch: Bool = true,
        notchRange: ClosedRange<CGFloat>? = 656 ... 856
    ) -> Monitor {
        Monitor(
            id: Monitor.ID(displayId: 1),
            displayId: 1,
            frame: frame,
            visibleFrame: CGRect(
                x: frame.minX,
                y: frame.minY,
                width: frame.width,
                height: visibleTop - frame.minY
            ),
            hasNotch: hasNotch,
            notchRange: notchRange,
            name: "Test"
        )
    }

    private func makeResolved(
        notchMode: WorkspaceBarNotchMode = .fillLeftOfNotch,
        position: WorkspaceBarPosition = .overlappingMenuBar,
        height: Double = 24,
        reserveLayoutSpace: Bool = false,
        xOffset: Double = 0,
        yOffset: Double = 0
    ) -> ResolvedBarSettings {
        ResolvedBarSettings(
            enabled: true,
            showLabels: true,
            showFloatingWindows: false,
            deduplicateAppIcons: false,
            hideEmptyWorkspaces: false,
            excludedBundleIDs: [],
            reserveLayoutSpace: reserveLayoutSpace,
            notchMode: notchMode,
            notchActiveZoneWidth: 180,
            systemStatsButton: false,
            position: position,
            windowLevel: .popup,
            height: height,
            backgroundOpacity: 0.1,
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
    }

    func testFillLeftOfNotchFrameCoversMenuBarToNotch() throws {
        let monitor = makeMonitor()
        let resolved = makeResolved(notchMode: .fillLeftOfNotch)
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)

        let frame = geometry.frame(fittingLength: 200, monitor: monitor, resolved: resolved)

        let expectedNotchStart = monitor.notchRange?.lowerBound ?? monitor.frame.midX
        let expectedMaxX = expectedNotchStart - WorkspaceBarGeometry.notchGap
        let expectedWidth = max(0, expectedMaxX - monitor.frame.minX)

        XCTAssertEqual(frame.minX, monitor.frame.minX)
        XCTAssertEqual(frame.maxX, expectedMaxX)
        XCTAssertEqual(frame.width, expectedWidth)
        XCTAssertEqual(frame.height, 32)
        XCTAssertEqual(frame.minY, monitor.frame.maxY - 32)
    }

    func testFillLeftOfNotchFrameUsesVirtualMidpointWithoutNotch() throws {
        let monitor = makeMonitor(hasNotch: false, notchRange: nil)
        let resolved = makeResolved(notchMode: .fillLeftOfNotch)
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)

        let frame = geometry.frame(fittingLength: 200, monitor: monitor, resolved: resolved)

        XCTAssertEqual(frame.minX, monitor.frame.minX)
        XCTAssertEqual(frame.maxX, monitor.frame.midX - WorkspaceBarGeometry.notchGap)
        XCTAssertEqual(frame.height, geometry.menuBarHeight)
        XCTAssertEqual(frame.minY, monitor.frame.maxY - geometry.menuBarHeight)
        XCTAssertEqual(geometry.effectivePosition, .overlappingMenuBar)
        XCTAssertEqual(geometry.barHeight, geometry.menuBarHeight)
        XCTAssertEqual(geometry.reservedInsets, .zero)
    }

    func testFillLeftOfNotchFrameWithTranslatedMonitor() throws {
        let monitor = makeMonitor(
            frame: CGRect(x: 100, y: 50, width: 1440, height: 900),
            visibleTop: 850,
            hasNotch: true,
            notchRange: 600 ... 840
        )
        let resolved = makeResolved(notchMode: .fillLeftOfNotch)
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)

        let frame = geometry.frame(fittingLength: 200, monitor: monitor, resolved: resolved)

        let expectedNotchStart = monitor.notchRange?.lowerBound ?? monitor.frame.midX
        let expectedMaxX = expectedNotchStart - WorkspaceBarGeometry.notchGap
        let expectedWidth = max(0, expectedMaxX - monitor.frame.minX)

        XCTAssertEqual(frame.minX, monitor.frame.minX)
        XCTAssertEqual(frame.maxX, expectedMaxX)
        XCTAssertEqual(frame.width, expectedWidth)
        XCTAssertEqual(frame.height, 100)
        XCTAssertEqual(frame.minY, monitor.frame.maxY - 100)
    }

    func testFillLeftOfNotchIgnoresCustomHeight() throws {
        let monitor = makeMonitor()
        let resolved = makeResolved(
            notchMode: .fillLeftOfNotch,
            position: .belowMenuBar,
            height: 30,
            reserveLayoutSpace: true,
            xOffset: 19,
            yOffset: -11
        )
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)

        let frame = geometry.frame(fittingLength: 200, monitor: monitor, resolved: resolved)

        let expectedNotchStart = monitor.notchRange?.lowerBound ?? monitor.frame.midX
        let expectedMaxX = expectedNotchStart - WorkspaceBarGeometry.notchGap
        let expectedWidth = max(0, expectedMaxX - monitor.frame.minX)

        XCTAssertEqual(frame.minX, monitor.frame.minX)
        XCTAssertEqual(frame.maxX, expectedMaxX)
        XCTAssertEqual(frame.width, expectedWidth)
        XCTAssertEqual(frame.height, 32)
        XCTAssertEqual(frame.minY, monitor.frame.maxY - 32)
        XCTAssertEqual(geometry.menuBarHeight, 32)
        XCTAssertEqual(geometry.barHeight, geometry.menuBarHeight)
        XCTAssertEqual(geometry.effectivePosition, .overlappingMenuBar)
        XCTAssertEqual(geometry.reservedInsets, .zero)
    }

    func testFillLeftOfNotchWithSplitModeIgnored() throws {
        let monitor = makeMonitor()
        let resolved = makeResolved(notchMode: .splitActiveLeft)
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)

        let frame = geometry.frame(fittingLength: 200, monitor: monitor, resolved: resolved)

        XCTAssertEqual(frame.width, 200)
        XCTAssertEqual(frame.minX, monitor.frame.midX - 100)
    }
}
