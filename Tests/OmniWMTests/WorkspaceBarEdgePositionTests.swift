// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarEdgePositionTests: XCTestCase {
    private let monitor = Monitor(
        id: .init(displayId: 7), displayId: 7,
        frame: CGRect(x: -1440, y: -900, width: 1440, height: 900),
        visibleFrame: CGRect(x: -1380, y: -840, width: 1320, height: 808),
        hasNotch: true, name: "External"
    )

    func testPositionsRoundTripGloballyAndPerDisplay() throws {
        for position in WorkspaceBarPosition.allCases {
            var export = SettingsExport.defaults()
            export.workspaceBar.position = position
            export.monitorBarSettings = [
                MonitorBarSettings(monitorName: monitor.name, position: position),
                MonitorBarSettings(monitorName: "Inherited")
            ]
            let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
            XCTAssertEqual(decoded.workspaceBar.position, position)
            XCTAssertEqual(decoded.monitorBarSettings.map(\.position), [position, nil])
        }
    }

    func testEdgesRespectDockOffsetsAndIgnoreNotchWithoutChangingPreferences() {
        let settings = WorkspaceBarSettings()
        settings.height = 32
        settings.xOffset = 5
        settings.yOffset = -7
        settings.reserveLayoutSpace = true
        let cases: [(WorkspaceBarPosition, CGRect, Struts)] = [
            (.bottom, CGRect(x: -815, y: -847, width: 200, height: 32), Struts(bottom: 32)),
            (.left, CGRect(x: -1375, y: -543, width: 32, height: 200), Struts(left: 32)),
            (.right, CGRect(x: -87, y: -543, width: 32, height: 200), Struts(right: 32))
        ]
        for (position, expectedFrame, insets) in cases {
            settings.position = position
            for mode in WorkspaceBarNotchMode.allCases {
                settings.notchMode = mode
                let resolved = settings.resolved(for: monitor)
                XCTAssertEqual(resolved.notchMode, .off)
                XCTAssertEqual(settings.notchMode, mode)
                let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
                XCTAssertEqual(geometry.frame(fittingLength: 200, monitor: monitor, resolved: resolved), expectedFrame)
                XCTAssertEqual(geometry.reservedInsets, insets)
                if position.isVertical {
                    XCTAssertEqual(
                        geometry.frame(fittingLength: 5000, monitor: monitor, resolved: resolved).height,
                        monitor.visibleFrame.height
                    )
                }
            }
            settings.update(MonitorBarSettings(monitorName: monitor.name, position: .belowMenuBar), for: monitor)
            XCTAssertEqual(settings.resolved(for: monitor).notchMode, settings.notchMode)
            settings.remove(for: monitor)
        }
    }

    func testHiddenBarsAndDisabledReservationsDoNotReserveSpace() {
        let settings = WorkspaceBarSettings()
        for position in WorkspaceBarPosition.allCases {
            settings.position = position
            for reserve in [false, true] {
                settings.reserveLayoutSpace = reserve
                for visible in [false, true] where !reserve || !visible {
                    XCTAssertEqual(WorkspaceBarGeometry.resolve(
                        monitor: monitor, resolved: settings.resolved(for: monitor), isVisible: visible
                    ).reservedInsets, .zero)
                }
            }
        }
    }

    func testFallbackIconAndPopupDoNotOverlapFullHeightSideBar() {
        let settings = WorkspaceBarSettings()
        for position in [WorkspaceBarPosition.left, .right] {
            settings.position = position
            let resolved = settings.resolved(for: monitor)
            let bar = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
                .frame(fittingLength: 5000, monitor: monitor, resolved: resolved)
            let icon = HiddenBarFallbackIconController.iconFrame(
                monitor: monitor, barVisible: true, barFrame: bar, position: position
            )
            XCTAssertFalse(icon.intersects(bar))
            XCTAssertTrue(monitor.visibleFrame.contains(icon))
            let popup = PopupAttachment(sourceFrame: icon, edge: position.popupEdge)
                .frame(size: CGSize(width: 300, height: 400), visibleFrame: monitor.visibleFrame)
            XCTAssertFalse(popup.intersects(icon))
            XCTAssertFalse(popup.intersects(bar))
        }
    }
}
