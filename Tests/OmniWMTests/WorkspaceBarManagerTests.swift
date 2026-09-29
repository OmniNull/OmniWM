// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class WorkspaceBarManagerTests: XCTestCase {
    private var controller: WMController!

    override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        controller = WMController(settings: settings)
    }

    override func tearDown() async throws {
        controller = nil
        try await super.tearDown()
    }

    func testPrimaryBarFrameChangesWithContent() {
        let manager = makeManager()
        defer { manager.cleanup() }

        manager.apply([barSurface(itemCount: 1)])
        let originalFrame = manager.barsByMonitor[monitor.id]?.primary.lastAppliedFrame
        XCTAssertNotNil(originalFrame)

        manager.apply([barSurface(itemCount: 4)])
        XCTAssertNotEqual(manager.barsByMonitor[monitor.id]?.primary.lastAppliedFrame, originalFrame)
    }

    func testIdenticalSceneKeepsPrimaryBarFrame() {
        let manager = makeManager()
        defer { manager.cleanup() }

        let scene = [barSurface(itemCount: 2)]
        manager.apply(scene)
        let originalFrame = manager.barsByMonitor[monitor.id]?.primary.lastAppliedFrame
        XCTAssertNotNil(originalFrame)

        manager.apply(scene)
        XCTAssertEqual(manager.barsByMonitor[monitor.id]?.primary.lastAppliedFrame, originalFrame)
    }

    func testEmptySceneRemovesPrimaryBar() {
        let manager = makeManager()

        manager.apply([barSurface(itemCount: 1)])
        XCTAssertNotNil(manager.barsByMonitor[monitor.id])

        manager.apply([])
        XCTAssertNil(manager.barsByMonitor[monitor.id])
    }

    func testHiddenBarPlacementUsesActualPrimaryIslandAndAppearance() throws {
        let manager = makeManager()
        defer { manager.cleanup() }
        manager.apply([barSurface(itemCount: 2)])
        let instance = try XCTUnwrap(manager.barsByMonitor[monitor.id])
        let frame = CGRect(x: 1200, y: 1000, width: 300, height: 24)
        instance.primary.panel.setFrame(frame, display: false)

        let placement = try XCTUnwrap(manager.hiddenBarPanelPlacement(on: monitor.id))

        XCTAssertEqual(placement.workspaceBar?.frame, frame)
        XCTAssertEqual(placement.workspaceBar?.backgroundStyle, instance.model.snapshot.backgroundStyle)
        XCTAssertEqual(placement.workspaceBar?.backgroundOpacity, instance.model.snapshot.backgroundOpacity)
        XCTAssertEqual(placement.visibleFrame, monitor.visibleFrame)
        manager.apply([])
        XCTAssertNil(manager.hiddenBarPanelPlacement(on: monitor.id))
    }

    func testHiddenBarJoinSquaresOnlyTheJoinedBar() throws {
        let manager = makeManager()
        defer { manager.cleanup() }
        manager.apply([barSurface(itemCount: 2)])
        let model = try XCTUnwrap(manager.barsByMonitor[monitor.id]?.model)

        controller.hiddenBarController.onWorkspaceBarJoin?(.init(monitorId: monitor.id, edge: .below))
        XCTAssertEqual(model.hiddenBarJoinEdge, .below)
        manager.setHiddenBarJoin(.init(monitorId: .init(displayId: 4_242), edge: .above))
        XCTAssertNil(model.hiddenBarJoinEdge)
        manager.setHiddenBarJoin(.init(monitorId: monitor.id, edge: .left))
        manager.apply([])
        manager.apply([barSurface(itemCount: 2)])
        XCTAssertEqual(manager.barsByMonitor[monitor.id]?.model.hiddenBarJoinEdge, .left)
        manager.setHiddenBarJoin(nil)
        XCTAssertNil(manager.barsByMonitor[monitor.id]?.model.hiddenBarJoinEdge)
    }

    func testJoinedBarSquaresOnlyItsFacingCorners() {
        let cases: [(PopupAttachment.Edge?, RectangleCornerRadii)] = [
            (nil, .init(topLeading: 8, bottomLeading: 8, bottomTrailing: 8, topTrailing: 8)),
            (.below, .init(topLeading: 8, bottomLeading: 0, bottomTrailing: 0, topTrailing: 8)),
            (.above, .init(topLeading: 0, bottomLeading: 8, bottomTrailing: 8, topTrailing: 0)),
            (.right, .init(topLeading: 8, bottomLeading: 8, bottomTrailing: 0, topTrailing: 0)),
            (.left, .init(topLeading: 0, bottomLeading: 0, bottomTrailing: 8, topTrailing: 8))
        ]
        for (edge, radii) in cases {
            XCTAssertEqual(WorkspaceBarView.barShape(joinedAt: edge).cornerRadii, radii, "\(String(describing: edge))")
        }
    }

    func testAutoHideReusesHiddenPanelsAndRetainsPopupAndDragInteractions() throws {
        controller.settings.workspaceBar.autoHide = true
        let manager = makeManager()
        defer {
            controller.systemStatsPopupController.dismiss()
            manager.cleanup()
        }
        var pointer = monitor.frame.center
        controller.currentMouseLocation = { pointer }
        var bar = barSurface(itemCount: 1)
        bar.visible = false
        bar.retainWhileHidden = true
        manager.apply([bar])
        let panel = try XCTUnwrap(manager.barsByMonitor[monitor.id]?.primary.panel)
        panel.setFrame(CGRect(x: 100, y: 100, width: 200, height: 24), display: false)
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(manager.popupAttachment(on: monitor.id))

        func apply() {
            manager.refreshAutoHide()
            bar.visible = manager.isPointerRevealed(on: monitor.id)
            manager.apply([bar])
        }

        pointer = panel.frame.center
        apply()
        XCTAssertTrue(panel.isVisible)
        XCTAssertNotNil(manager.popupAttachment(on: monitor.id))
        controller.systemStatsPopupController.toggle(
            attachment: try XCTUnwrap(manager.popupAttachment(on: monitor.id)),
            monitorId: monitor.id, screenVisibleFrame: monitor.visibleFrame
        )
        pointer = monitor.frame.center
        apply()
        XCTAssertTrue(panel.isVisible)
        controller.systemStatsPopupController.dismiss()
        apply()
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(manager.barsByMonitor[monitor.id]?.primary.panel === panel)

        pointer = panel.frame.center
        apply()
        manager.dragController.sourceIsValid = { _ in true }
        manager.dragController.begin(
            source: .init(
                tokens: [WindowToken(pid: 42, windowId: 42)],
                workspaceId: bar.snapshot.items[0].id,
                isFloating: false
            ),
            icon: nil, at: pointer
        )
        pointer = monitor.frame.center
        apply()
        XCTAssertTrue(panel.isVisible)
        manager.dragController.cancel()
        apply()
        XCTAssertFalse(panel.isVisible)
        manager.cleanup()
        XCTAssertFalse(manager.autoHideMonitor.isRunning)
        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))
        XCTAssertTrue(manager.barsByMonitor.isEmpty)
    }

    func testAutoHideSuppressionAndMonitorRemovalClearReveal() throws {
        controller.settings.workspaceBar.autoHide = true
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let manager = controller.workspaceBarManager
        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }
        var pointer = CGPoint(x: -10000, y: -10000)
        controller.currentMouseLocation = { pointer }
        var bar = barSurface(itemCount: 1)
        bar.visible = false
        bar.retainWhileHidden = true
        manager.apply([bar])
        let panel = try XCTUnwrap(manager.barsByMonitor[monitor.id]?.primary.panel)
        panel.setFrame(CGRect(x: 100, y: 100, width: 200, height: 24), display: false)
        pointer = panel.frame.center
        manager.refreshAutoHide()
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
        controller.settings.workspaceBar.revealModifier = .option
        pointer = monitor.frame.center
        manager.refreshAutoHide()
        controller.setWorkspaceBarRevealHeld(true)
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
        controller.setWorkspaceBarRevealHeld(false)
        XCTAssertFalse(controller.isWorkspaceBarVisible(on: monitor))
        pointer = panel.frame.center
        manager.refreshAutoHide()
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
        XCTAssertTrue(controller.toggleWorkspaceBarVisibility())
        manager.refreshAutoHide()
        XCTAssertFalse(controller.isWorkspaceBarVisible(on: monitor))
        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))
        XCTAssertTrue(controller.toggleWorkspaceBarVisibility())
        controller.settings.workspaceBar.hideInNativeFullscreen = true
        controller.workspaceManager.commitSpaceTopology(SpaceTopology(
            displays: [.init(displayIdentifier: String(monitor.displayId), spaceIds: [1], currentSpaceId: 1)],
            activeSpaceId: 1, fullscreenSpaceIds: [1], windowSpace: [:]
        ))
        manager.refreshAutoHide()
        XCTAssertFalse(controller.isWorkspaceBarVisible(on: monitor))
        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))
        controller.settings.workspaceBar.hideInNativeFullscreen = false
        manager.refreshAutoHide()
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
        controller.settings.workspaceBar.enabled = false
        manager.refreshAutoHide()
        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))
        manager.apply([])
        XCTAssertFalse(manager.autoHideMonitor.isRunning)
    }

    private func makeManager() -> WorkspaceBarManager {
        let manager = WorkspaceBarManager(motionPolicy: MotionPolicy(animationsEnabled: false))
        manager.setup(controller: controller, settings: controller.settings)
        manager.panelFactory = { WorkspaceBarPanel.defaultPanel() }
        manager.frameApplier = { _, _ in }
        return manager
    }

    private func barSurface(itemCount: Int) -> DesiredBarSurface {
        DesiredBarSurface(monitor: monitor, visible: true, snapshot: snapshot(itemCount: itemCount))
    }

    private var monitor: Monitor {
        Monitor(
            id: .init(displayId: 92_200), displayId: 92_200,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055),
            hasNotch: false, name: "Test"
        )
    }

    private func snapshot(itemCount: Int) -> WorkspaceBarSnapshot {
        let items = (0 ..< itemCount).map { index in
            WorkspaceBarItem(
                id: WorkspaceDescriptor.ID(),
                name: "Workspace \(index)",
                rawName: "Workspace \(index)",
                isFocused: index == 0,
                tiledWindows: [],
                floatingWindows: []
            )
        }
        return WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: items, scratchpads: []),
            showLabels: true,
            showSystemStatsButton: false,
            backgroundOpacity: 0.6,
            barHeight: 24,
            accentColor: nil,
            textColor: nil
        )
    }
}
