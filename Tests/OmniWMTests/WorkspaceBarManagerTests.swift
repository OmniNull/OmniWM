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
        bar.snapshot = snapshot(itemCount: 1, showSystemStatsButton: true)
        bar.visible = false
        bar.retainWhileHidden = true
        manager.apply([bar])
        let panel = try XCTUnwrap(manager.barsByMonitor[monitor.id]?.primary.panel)
        panel.setFrame(CGRect(x: 100, y: monitor.frame.maxY - 24, width: 200, height: 24), display: false)
        manager.rebuildAutoHideTargets()
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(manager.popupAttachment(on: monitor.id))

        func applyVisibility() {
            bar.visible = manager.isPointerRevealed(on: monitor.id)
            manager.apply([bar])
        }

        pointer = CGPoint(x: panel.frame.midX, y: monitor.frame.maxY - 0.5)
        manager.handleAutoHideMouseMoved(at: pointer)
        applyVisibility()
        XCTAssertTrue(panel.isVisible)
        XCTAssertNotNil(manager.popupAttachment(on: monitor.id))
        controller.systemStatsPopupController.toggle(
            attachment: try XCTUnwrap(manager.popupAttachment(on: monitor.id)),
            monitorId: monitor.id, screenVisibleFrame: monitor.visibleFrame
        )
        pointer = monitor.frame.center
        manager.handleAutoHideMouseMoved(at: pointer)
        applyVisibility()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(controller.systemStatsPopupController.isVisible)

        controller.systemStatsPopupController.dismiss()
        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))
        applyVisibility()
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(manager.barsByMonitor[monitor.id]?.primary.panel === panel)

        pointer = CGPoint(x: panel.frame.midX, y: monitor.frame.maxY - 0.5)
        manager.handleAutoHideMouseMoved(at: pointer)
        applyVisibility()
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
        manager.handleAutoHideMouseMoved(at: pointer)
        applyVisibility()
        XCTAssertTrue(panel.isVisible)
        manager.dragController.cancel()
        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))
        applyVisibility()
        XCTAssertFalse(panel.isVisible)
        manager.cleanup()
        XCTAssertFalse(manager.needsAutoHideMouseMoves)
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
        panel.setFrame(CGRect(x: 100, y: monitor.frame.maxY - 24, width: 200, height: 24), display: false)
        pointer = CGPoint(x: panel.frame.midX, y: monitor.frame.maxY - 0.5)
        manager.rebuildAutoHideTargets()
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
        controller.settings.workspaceBar.revealModifier = .option
        pointer = monitor.frame.center
        manager.handleAutoHideMouseMoved(at: pointer)
        controller.setWorkspaceBarRevealHeld(true)
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
        controller.setWorkspaceBarRevealHeld(false)
        XCTAssertFalse(controller.isWorkspaceBarVisible(on: monitor))
        pointer = CGPoint(x: panel.frame.midX, y: monitor.frame.maxY - 0.5)
        manager.handleAutoHideMouseMoved(at: pointer)
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
        XCTAssertTrue(controller.toggleWorkspaceBarVisibility())
        manager.rebuildAutoHideTargets()
        XCTAssertFalse(controller.isWorkspaceBarVisible(on: monitor))
        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))
        XCTAssertFalse(manager.needsAutoHideMouseMoves)
        XCTAssertTrue(controller.toggleWorkspaceBarVisibility())
        controller.settings.workspaceBar.hideInNativeFullscreen = true
        controller.workspaceManager.commitSpaceTopology(SpaceTopology(
            displays: [.init(displayIdentifier: String(monitor.displayId), spaceIds: [1], currentSpaceId: 1)],
            activeSpaceId: 1, fullscreenSpaceIds: [1], windowSpace: [:]
        ))
        manager.rebuildAutoHideTargets()
        XCTAssertFalse(controller.isWorkspaceBarVisible(on: monitor))
        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))
        XCTAssertFalse(manager.needsAutoHideMouseMoves)
        controller.settings.workspaceBar.hideInNativeFullscreen = false
        manager.rebuildAutoHideTargets()
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
        controller.settings.workspaceBar.enabled = false
        manager.rebuildAutoHideTargets()
        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))
        manager.apply([])
        XCTAssertFalse(manager.needsAutoHideMouseMoves)
    }

    func testAutoHideMouseMoveDemandAndDispatchAcrossDisplays() throws {
        let second = Monitor(
            id: .init(displayId: 92_201), displayId: 92_201,
            frame: CGRect(x: -1920, y: 1080, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: 1080, width: 1920, height: 1055),
            hasNotch: false, name: "Second"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor, second])
        controller.settings.pointer.enabled = false
        controller.setFocusFollowsMouse(false)
        var pointer = monitor.frame.center
        controller.currentMouseLocation = { pointer }
        let manager = controller.workspaceBarManager
        manager.setup(controller: controller, settings: controller.settings)
        manager.frameApplier = { _, _ in }
        defer { manager.cleanup() }
        let handler = controller.mouseEventHandler
        var bars = [monitor, second].map {
            DesiredBarSurface(monitor: $0, visible: false, snapshot: snapshot(itemCount: 1), retainWhileHidden: true)
        }
        manager.apply(bars)
        XCTAssertFalse(handler.mouseMovesNeeded)

        controller.settings.workspaceBar.autoHide = true
        manager.apply(bars)
        XCTAssertTrue(handler.mouseMovesNeeded)
        for display in [monitor, second] {
            let panel = try XCTUnwrap(manager.barsByMonitor[display.id]?.primary.panel)
            panel.setFrame(
                CGRect(x: display.frame.minX + 100, y: display.frame.maxY - 24, width: 200, height: 24),
                display: false
            )
        }
        manager.rebuildAutoHideTargets()

        pointer = CGPoint(x: 200, y: 1079.5)
        handler.dispatchMouseMoved(at: pointer)
        XCTAssertTrue(manager.isPointerRevealed(on: monitor.id))
        XCTAssertFalse(manager.isPointerRevealed(on: second.id))
        bars[0].visible = true
        manager.apply(bars)
        manager.handleAutoHideMouseMoved(at: monitor.frame.center)
        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))
        XCTAssertTrue(controller.isPointInOwnWindow(pointer))
        controller.setFocusFollowsMouse(true)
        handler.dispatchMouseMoved(at: pointer)
        XCTAssertTrue(manager.isPointerRevealed(on: monitor.id))
        controller.setFocusFollowsMouse(false)

        pointer = CGPoint(x: -1720, y: 2159.5)
        handler.dispatchQueuedMouseDragged(at: pointer, button: .left)
        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))
        XCTAssertTrue(manager.isPointerRevealed(on: second.id))

        manager.apply([bars[0]])
        XCTAssertFalse(manager.isPointerRevealed(on: second.id))
        XCTAssertTrue(handler.mouseMovesNeeded)
        controller.settings.workspaceBar.autoHide = false
        manager.apply([bars[0]])
        XCTAssertFalse(handler.mouseMovesNeeded)

        controller.settings.workspaceBar.autoHide = true
        manager.apply([bars[0]])
        XCTAssertTrue(handler.mouseMovesNeeded)
        manager.cleanup()
        XCTAssertFalse(handler.mouseMovesNeeded)
    }

    func testSheetDismissalUpdatesAutoHideWithoutPointerMovement() throws {
        controller.settings.workspaceBar.autoHide = true
        let manager = makeManager()
        defer { manager.cleanup() }
        var pointer = monitor.frame.center
        controller.currentMouseLocation = { pointer }
        var bar = barSurface(itemCount: 1)
        bar.retainWhileHidden = true
        manager.apply([bar])
        let panel = try XCTUnwrap(manager.barsByMonitor[monitor.id]?.primary.panel)
        panel.setFrame(CGRect(x: 100, y: monitor.frame.maxY - 24, width: 200, height: 24), display: false)
        manager.rebuildAutoHideTargets()
        XCTAssertTrue(panel.delegate === panel)

        panel.windowWillBeginSheet(Notification(name: NSWindow.willBeginSheetNotification, object: panel))
        XCTAssertTrue(manager.isPointerRevealed(on: monitor.id))
        pointer = CGPoint(x: 500, y: 500)
        manager.handleAutoHideMouseMoved(at: pointer)
        XCTAssertTrue(manager.isPointerRevealed(on: monitor.id))

        panel.windowDidEndSheet(Notification(name: NSWindow.didEndSheetNotification, object: panel))
        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))
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

    private func snapshot(itemCount: Int, showSystemStatsButton: Bool = false) -> WorkspaceBarSnapshot {
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
            showSystemStatsButton: showSystemStatsButton,
            backgroundOpacity: 0.6,
            barHeight: 24,
            accentColor: nil,
            textColor: nil
        )
    }
}
