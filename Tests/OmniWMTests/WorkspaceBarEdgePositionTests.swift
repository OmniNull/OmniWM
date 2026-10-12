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
        visibleFrame: CGRect(x: -1380, y: -840, width: 1380, height: 808),
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
        settings.notchMode = .splitActiveLeft
        let cases: [(WorkspaceBarPosition, CGRect, Struts)] = [
            (.bottom, CGRect(x: -785, y: -847, width: 200, height: 32), Struts(bottom: 32)),
            (.left, CGRect(x: -1375, y: -543, width: 32, height: 200), Struts(left: 32)),
            (.right, CGRect(x: -27, y: -543, width: 32, height: 200), Struts(right: 32))
        ]
        for (position, expectedFrame, insets) in cases {
            settings.position = position
            let resolved = settings.resolved(for: monitor)
            XCTAssertEqual(resolved.notchMode, .off)
            XCTAssertEqual(settings.notchMode, .splitActiveLeft)
            let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
            XCTAssertEqual(geometry.frame(fittingLength: 200, monitor: monitor, resolved: resolved), expectedFrame)
            XCTAssertEqual(geometry.reservedInsets, insets)
            XCTAssertEqual(
                geometry.frame(fittingLength: 5000, monitor: monitor, resolved: resolved).height,
                position.isVertical ? monitor.visibleFrame.height : 32
            )
        }
        settings.update(MonitorBarSettings(monitorName: monitor.name, position: .belowMenuBar), for: monitor)
        XCTAssertEqual(settings.resolved(for: monitor).notchMode, .splitActiveLeft)
    }

    func testOverlappingReservationTracksScreenConstrainedBar() {
        let monitor = Monitor(
            id: .init(displayId: 7), displayId: 7,
            frame: CGRect(x: -1440, y: -900, width: 1440, height: 900),
            visibleFrame: CGRect(x: -1380, y: -840, width: 1380, height: 810),
            hasNotch: false, name: "External"
        )
        let settings = WorkspaceBarSettings()
        settings.position = .overlappingMenuBar
        settings.notchMode = .off
        settings.reserveLayoutSpace = true
        let cases: [(height: Double, yOffset: Double, reservedTop: CGFloat)] = [
            (24, 0, 0),
            (32, 0, 2),
            (40, 0, 10),
            (32, -5, 5),
            (32, 5, 2),
            (24, -10, 10),
            (24, 10, 0),
            (24, -2000, 870),
            (0, -10, 0),
            (-10, -10, 0)
        ]
        for testCase in cases {
            settings.height = testCase.height
            settings.yOffset = testCase.yOffset
            let resolved = settings.resolved(for: monitor)
            let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
            XCTAssertEqual(
                geometry.reservedInsets, Struts(top: testCase.reservedTop),
                "height=\(testCase.height), yOffset=\(testCase.yOffset)"
            )
        }
    }

    func testOverlapDoesNotReserveWhenHiddenOrReservationDisabled() {
        let settings = WorkspaceBarSettings()
        settings.position = .overlappingMenuBar
        settings.notchMode = .off
        settings.height = 40
        settings.yOffset = -10
        settings.reserveLayoutSpace = true
        XCTAssertEqual(
            WorkspaceBarGeometry.resolve(
                monitor: monitor, resolved: settings.resolved(for: monitor), isVisible: false
            ).reservedInsets,
            .zero
        )
        settings.reserveLayoutSpace = false
        XCTAssertEqual(
            WorkspaceBarGeometry.resolve(
                monitor: monitor, resolved: settings.resolved(for: monitor), isVisible: true
            ).reservedInsets,
            .zero
        )
    }

    func testBelowMenuBarAndNotchFallbackKeepFullHeightReservation() {
        let settings = WorkspaceBarSettings()
        settings.height = 24
        settings.yOffset = -7
        settings.reserveLayoutSpace = true
        let cases: [(WorkspaceBarPosition, WorkspaceBarNotchMode)] = [
            (.belowMenuBar, .off),
            (.overlappingMenuBar, .moveBelowMenuBar),
            (.overlappingMenuBar, .rightOfNotch)
        ]
        for (position, notchMode) in cases {
            settings.position = position
            settings.notchMode = notchMode
            let resolved = settings.resolved(for: monitor)
            let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
            XCTAssertEqual(geometry.effectivePosition, .belowMenuBar)
            XCTAssertEqual(geometry.reservedInsets, Struts(top: 24))
        }
    }

    func testOverlappingReservationMatchesPanelFrame() throws {
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("Requires an NSScreen to check the panel's frame constraint")
        }
        let monitor = Monitor(
            id: .init(displayId: 7), displayId: 7,
            frame: screen.frame, visibleFrame: screen.visibleFrame,
            hasNotch: false, name: "Test"
        )
        let panel = WorkspaceBarPanel.defaultPanel()
        defer { panel.close() }
        let settings = WorkspaceBarSettings()
        settings.position = .overlappingMenuBar
        settings.notchMode = .off
        settings.height = Double(screen.frame.maxY - screen.visibleFrame.maxY + 2)
        settings.reserveLayoutSpace = true
        for yOffset in [-5.0, 0, 10] {
            settings.yOffset = yOffset
            let resolved = settings.resolved(for: monitor)
            let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
            let frame = panel.constrainFrameRect(
                geometry.frame(fittingLength: 200, monitor: monitor, resolved: resolved), to: screen
            )
            XCTAssertEqual(geometry.reservedInsets.top, max(0, monitor.visibleFrame.maxY - frame.minY))
        }
    }

    func testStatsAttachmentTracksDisplayedBarAfterMovement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: root, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        settings.workspaceBar.height = 32
        let controller = WMController(settings: settings)
        let manager = controller.workspaceBarManager
        let panel = WorkspaceBarPanel.defaultPanel()
        manager.setup(controller: controller, settings: settings)
        manager.screenProvider = { _ in nil }
        manager.panelFactory = { panel }
        defer { manager.cleanup() }

        for position in [WorkspaceBarPosition.bottom, .left, .right] {
            settings.workspaceBar.position = position
            let snapshot = WorkspaceBarSnapshot(
                projection: WorkspaceBarProjection(items: [], scratchpads: []),
                showLabels: true, showSystemStatsButton: true, backgroundOpacity: 0.5,
                barHeight: 32, accentColor: nil, textColor: nil,
                orientation: position.isVertical ? .vertical : .horizontal
            )
            manager.apply([DesiredBarSurface(monitor: monitor, visible: true, snapshot: snapshot)])
            for _ in 0 ..< 100 where manager.statsAnchor(on: monitor.id) == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            let anchor = try XCTUnwrap(manager.statsAnchor(on: monitor.id))
            let frame = panel.frame.offsetBy(dx: 10, dy: 10)
            panel.setFrame(frame, display: true)
            let moved = try XCTUnwrap(manager.statsAnchor(on: monitor.id))
            XCTAssertEqual(moved.x - anchor.x, 10, accuracy: 0.5)
            XCTAssertEqual(moved.y - anchor.y, 10, accuracy: 0.5)
            XCTAssertEqual(manager.popupAttachment(on: monitor.id, forStats: true), PopupAttachment(
                sourceFrame: frame, edge: position.popupEdge, alignment: moved
            ))
        }
    }
}
