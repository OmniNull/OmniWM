// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarPopupIntegrationTests: XCTestCase {
    func testControllerHiddenPanelUsesDisplayedFrameRatherThanRequestedOffset() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.settings.workspaceBar.position = .bottom
        fixture.settings.workspaceBar.yOffset = -10000
        fixture.applyBar()
        let placement = try XCTUnwrap(fixture.controller.hiddenBarPanelPlacement())
        XCTAssertEqual(placement.attachment.edge, .above)
        XCTAssertEqual(placement.attachment.anchor.y, fixture.barPanel.frame.maxY)
        XCTAssertEqual(fixture.manager.primaryDisplayedFrame(on: fixture.monitor.id), fixture.barPanel.frame)
        let panel = HiddenBarPanelController()
        defer { panel.dismiss() }
        panel.toggle(placement: placement, items: [])
        let frame = try XCTUnwrap(panel.panel?.frame)
        XCTAssertGreaterThanOrEqual(frame.minY, fixture.barPanel.frame.maxY + 4)
        XCTAssertFalse(frame.intersects(fixture.barPanel.frame))
    }

    func testAllPositionsAttachToDisplayedEdgesAndHiddenBarFallsBackToTop() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for position in WorkspaceBarPosition.allCases {
            fixture.settings.workspaceBar.position = position
            fixture.applyBar()
            let attachment = try XCTUnwrap(fixture.controller.hiddenBarPanelPlacement()).attachment
            XCTAssertEqual(attachment, PopupAttachment(sourceFrame: fixture.barPanel.frame, edge: position.popupEdge))
        }
        fixture.settings.workspaceBar.enabled = false
        let placement = try XCTUnwrap(fixture.controller.hiddenBarPanelPlacement())
        XCTAssertEqual(placement.attachment.edge, .below)
        XCTAssertEqual(placement.attachment.anchor.y, fixture.monitor.visibleFrame.maxY)
    }

    func testFallbackStatusMenuOpensInwardAndRealStatusItemStillOpensDown() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let iconPanel = WorkspaceBarPanel.defaultPanel()
        iconPanel.targetScreen = fixture.screen
        let icon = HiddenBarFallbackIconButton(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        iconPanel.contentView = icon
        let host = StatusMenuHost(
            model: StatusMenuModel(settings: fixture.settings, controller: fixture.controller),
            controller: fixture.controller
        )
        defer { host.dismiss()
            iconPanel.close()
        }
        for position in [WorkspaceBarPosition.bottom, .left, .right] {
            fixture.settings.workspaceBar.position = position
            fixture.applyBar()
            iconPanel.setFrame(HiddenBarFallbackIconController.iconFrame(
                monitor: fixture.monitor, barVisible: true, barFrame: fixture.barPanel.frame, position: position
            ), display: true)
            iconPanel.orderFrontRegardless()
            let attachment = try XCTUnwrap(fixture.controller.statusMenuAttachment(from: icon))
            XCTAssertEqual(attachment.edge, position.popupEdge)
            host.toggle(from: icon, attachment: attachment)
            let frame = try XCTUnwrap(host.panel?.frame)
            XCTAssertFalse(frame.intersects(iconPanel.frame))
            XCTAssertFalse(frame.intersects(fixture.barPanel.frame))
            host.dismiss()
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        XCTAssertEqual(fixture.controller.statusMenuAttachment(from: button)?.edge, .below)
        fixture.settings.workspaceBar.enabled = false
        XCTAssertEqual(fixture.controller.statusMenuAttachment(from: icon)?.edge, .below)
    }

    func testStatsControllerUsesActualBarEdgeForAllDockedPositions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for position in [WorkspaceBarPosition.bottom, .left, .right] {
            fixture.settings.workspaceBar.position = position
            fixture.settings.workspaceBar.yOffset = position == .bottom ? -10000 : 0
            fixture.applyBar()
            fixture.barPanel.contentView?.layoutSubtreeIfNeeded()
            for _ in 0 ..< 100 where fixture.manager.statsAnchor(on: fixture.monitor.id) == nil {
                try await Task.sleep(for: .milliseconds(10))
                fixture.barPanel.contentView?.layoutSubtreeIfNeeded()
            }
            let originalAnchor = try XCTUnwrap(fixture.manager.statsAnchor(on: fixture.monitor.id))
            fixture.barPanel.setFrame(fixture.barPanel.frame.offsetBy(dx: 0, dy: 10), display: true)
            let movedAnchor = try XCTUnwrap(fixture.manager.statsAnchor(on: fixture.monitor.id))
            XCTAssertEqual(movedAnchor.y - originalAnchor.y, 10, accuracy: 0.5)
            fixture.controller.toggleSystemStatsFromBar(on: fixture.monitor.id)
            XCTAssertTrue(fixture.controller.systemStatsPopupController.isVisible)
            let frame = try XCTUnwrap(fixture.controller.systemStatsPopupController.panel?.frame)
            XCTAssertFalse(frame.intersects(fixture.barPanel.frame))
            fixture.controller.systemStatsPopupController.dismiss()
        }
    }

    func testSplitStatsAttachmentUsesTheSecondaryDisplayedIsland() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.applyBar()
        fixture.settings.workspaceBar.notchMode = .splitActiveLeft
        let secondary = WorkspaceBarPanel.defaultPanel()
        fixture.manager.panelFactory = { secondary }
        fixture.manager.frameApplier = { panel, requested in
            let frame = requested.offsetBy(dx: 0, dy: panel === secondary ? -60 : 0)
            panel.setFrame(panel.constrainFrameRect(frame, to: panel.targetScreen), display: true)
        }
        let items = [true, false].map { focused in
            WorkspaceBarItem(
                id: UUID(), name: focused ? "1" : "2", rawName: focused ? "1" : "2",
                isFocused: focused, tiledWindows: [], floatingWindows: []
            )
        }
        let snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: items, scratchpads: []),
            showLabels: true, showSystemStatsButton: true, backgroundOpacity: 0.5,
            barHeight: 32, accentColor: nil, textColor: nil
        )
        fixture.manager.apply([DesiredBarSurface(monitor: fixture.monitor, visible: true, snapshot: snapshot)])
        secondary.contentView?.layoutSubtreeIfNeeded()
        for _ in 0 ..< 100 {
            if let point = fixture.manager.statsAnchor(on: fixture.monitor.id),
               secondary.frame.contains(point) { break }
            try await Task.sleep(for: .milliseconds(10))
            secondary.contentView?.layoutSubtreeIfNeeded()
        }
        let attachment = try XCTUnwrap(fixture.manager.popupAttachment(on: fixture.monitor.id, forStats: true))
        XCTAssertEqual(attachment.edge, .below)
        XCTAssertEqual(attachment.anchor.y, secondary.frame.minY)
        XCTAssertNotEqual(attachment.anchor.y, fixture.barPanel.frame.minY)
        XCTAssertTrue(secondary.frame.contains(try XCTUnwrap(fixture.manager.statsAnchor(on: fixture.monitor.id))))
    }

    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings: SettingsStore
        let controller: WMController
        let monitor: Monitor
        let screen: NSScreen
        let barPanel = WorkspaceBarPanel.defaultPanel()
        var manager: WorkspaceBarManager {
            controller.workspaceBarManager
        }

        init() throws {
            screen = try XCTUnwrap(NSScreen.main)
            let displayId = try XCTUnwrap(screen.displayId)
            monitor = Monitor(
                id: .init(displayId: displayId), displayId: displayId,
                frame: screen.frame, visibleFrame: screen.visibleFrame, hasNotch: false, name: "Test"
            )
            settings = SettingsStore(
                persistence: SettingsFilePersistence(directory: root, startWatching: false, deferSaves: false),
                runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
                autosaveEnabled: false
            )
            settings.workspaceBar.height = 32
            settings.workspaceBar.systemStatsButton = true
            controller = WMController(settings: settings)
            controller.workspaceManager.replaceMonitorsForTopologyTransition(with: [monitor])
            let monitor = monitor
            controller.currentMouseLocation = { monitor.frame.center }
            manager.setup(controller: controller, settings: settings)
            let barPanel = barPanel
            manager.panelFactory = { barPanel }
            manager.frameApplier = { panel, requested in
                panel.setFrame(panel.constrainFrameRect(requested, to: panel.targetScreen), display: true)
            }
        }

        func applyBar() {
            let snapshot = WorkspaceBarSnapshot(
                projection: WorkspaceBarProjection(items: [], scratchpads: []),
                showLabels: true, showSystemStatsButton: true, backgroundOpacity: 0.5,
                barHeight: 32, accentColor: nil, textColor: nil,
                orientation: settings.workspaceBar.position.isVertical ? .vertical : .horizontal
            )
            manager.apply([DesiredBarSurface(monitor: monitor, visible: true, snapshot: snapshot)])
            barPanel.contentView?.layoutSubtreeIfNeeded()
        }

        func cleanup() {
            controller.systemStatsPopupController.dismiss()
            manager.cleanup()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
