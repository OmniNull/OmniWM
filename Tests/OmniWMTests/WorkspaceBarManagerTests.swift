// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
        let shell = root.appendingPathComponent("config/shell", isDirectory: true)
        try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)
        try Data("profiles.default.leading = []\nprofiles.default.center = []\nprofiles.default.trailing = []\n".utf8)
            .write(to: shell.appendingPathComponent("shell.toml"))
        controller = WMController(settings: settings)
    }

    override func tearDown() async throws {
        controller = nil
        try await super.tearDown()
    }

    func testPrimaryBarFrameChangesWithContent() async throws {
        executionTimeAllowance = 60
        let widget = controller.settings.settingsFileURL.deletingLastPathComponent()
            .appendingPathComponent("shell/widgets/count", isDirectory: true)
        try FileManager.default.createDirectory(at: widget, withIntermediateDirectories: true)
        try Data("function render(ctx) return ui.box{ w = 10 * #ctx.data.bar.workspaces, h = 10 } end".utf8)
            .write(to: widget.appendingPathComponent("init.luau"))
        try Data(
            "profiles.default.leading = []\nprofiles.default.center = []\nprofiles.default.trailing = [\"count\"]\n[profiles.default.workspaceBar]\nfullWidth = false\n"
                .utf8
        )
        .write(to: widget.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shell.toml"))
        let manager = makeManager()
        defer { manager.cleanup() }
        func width(after bar: DesiredBarSurface, is expected: CGFloat) async throws -> NSRect? {
            manager.apply([bar])
            let model = try XCTUnwrap(manager.barsByMonitor[monitor.id]?.model)
            while model.snapshot.shellWidgets.first?.size.width != expected {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = model.snapshot
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
            return manager.barsByMonitor[monitor.id]?.primary.lastAppliedFrame
        }

        let originalFrame = try await width(after: barSurface(itemCount: 1), is: 10)
        XCTAssertNotNil(originalFrame)
        let wider = try await width(after: barSurface(itemCount: 4), is: 40)
        XCTAssertNotEqual(wider, originalFrame)
    }

    func testPressingABarCancelsAnUnfinishedDrag() throws {
        let manager = makeManager()
        defer { manager.cleanup() }
        let bar = barSurface(itemCount: 1)
        manager.apply([bar])
        let panel = try XCTUnwrap(manager.barsByMonitor[monitor.id]?.primary.panel)
        manager.dragController.sourceIsValid = { _ in true }
        manager.dragController.begin(
            source: .init(
                tokens: [WindowToken(pid: 42, windowId: 42)],
                workspaceId: bar.snapshot.items[0].id,
                isFloating: false
            ),
            icon: nil, at: .zero
        )
        XCTAssertTrue(manager.dragController.isDragging)

        let press = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
        panel.sendEvent(press)
        XCTAssertFalse(manager.dragController.isDragging)
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

    func testSavingBelowMenuBarMovesTheExistingPanelWhenTheSystemMenuBarIsHidden() async throws {
        let manager = makeManager()
        manager.screenProvider = { _ in nil }
        manager.frameApplier = { panel, frame in panel.setFrame(frame, display: false) }
        defer { manager.cleanup() }
        try await manager.shellConfiguration.set(true, key: "fullWidth")
        try await manager.shellConfiguration.set(WorkspaceBarWindowLevel.normal, key: "windowLevel")
        try await manager.shellConfiguration.set(WorkspaceBarPosition.overlappingMenuBar, key: "position")
        let monitor = Monitor(
            id: .init(displayId: 92_200), displayId: 92_200,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055),
            hasNotch: false, name: "Test"
        )
        let bar = DesiredBarSurface(monitor: monitor, visible: true, snapshot: snapshot(itemCount: 1))
        manager.apply([bar])
        let instance = try XCTUnwrap(manager.barsByMonitor[monitor.id])
        let original = try XCTUnwrap(instance.primary.lastAppliedFrame)
        let panel = instance.primary.panel
        XCTAssertEqual(panel.frame, original)
        XCTAssertEqual(original.maxY, monitor.frame.maxY)
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.statusBar.rawValue)

        try await manager.shellConfiguration.set(WorkspaceBarPosition.belowMenuBar, key: "position")
        manager.apply([bar])
        let below = try XCTUnwrap(instance.primary.lastAppliedFrame)
        XCTAssertTrue(manager.barsByMonitor[monitor.id] === instance)
        XCTAssertTrue(instance.primary.panel === panel)
        XCTAssertEqual(below.maxY, monitor.frame.maxY - 28)
        XCTAssertNotEqual(below, original)
        XCTAssertEqual(panel.frame, below)
        XCTAssertEqual(panel.level, .normal)

        try await manager.shellConfiguration.set(WorkspaceBarPosition.overlappingMenuBar, key: "position")
        manager.apply([bar])
        XCTAssertTrue(instance.primary.panel === panel)
        XCTAssertEqual(instance.primary.lastAppliedFrame, original)
        XCTAssertEqual(panel.frame, original)
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.statusBar.rawValue)
    }

    func testSavingBelowWithVisibleMenusRepairsActualPanelDriftInBothWidthModes() async throws {
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("Requires an NSScreen to check the actual panel frame")
        }
        let monitor = Monitor(
            id: .init(displayId: 92_200), displayId: 92_200,
            frame: screen.frame, visibleFrame: screen.visibleFrame,
            hasNotch: false, name: "Test"
        )
        guard screen.frame.maxY > screen.visibleFrame.maxY + 1 else {
            throw XCTSkip("Requires a screen with a visible menu bar strip")
        }
        for fullWidth in [false, true] {
            let manager = makeManager()
            manager.screenProvider = { _ in screen }
            manager.frameApplier = { panel, frame in panel.setFrame(frame, display: false) }
            defer { manager.cleanup() }
            try await manager.shellConfiguration.set(fullWidth, key: "fullWidth")
            try await manager.shellConfiguration.set(WorkspaceBarNotchMode.off, key: "notchMode")
            try await manager.shellConfiguration.set(WorkspaceBarPosition.overlappingMenuBar, key: "position")
            let bar = DesiredBarSurface(
                monitor: monitor, visible: false, snapshot: snapshot(itemCount: 1), retainWhileHidden: true
            )
            manager.apply([bar])
            let instance = try XCTUnwrap(manager.barsByMonitor[monitor.id])
            let panel = instance.primary.panel
            let overlapping = panel.frame

            try await manager.shellConfiguration.set(WorkspaceBarPosition.belowMenuBar, key: "position")
            manager.apply([bar])
            let below = panel.frame
            XCTAssertLessThan(below.minY, overlapping.minY)
            XCTAssertEqual(below.maxY, screen.visibleFrame.maxY)

            panel.setFrame(overlapping, display: false)
            XCTAssertEqual(controller.settings.workspaceBar.resolved(for: monitor).position, .belowMenuBar)
            manager.apply([bar])

            XCTAssertTrue(manager.barsByMonitor[monitor.id] === instance)
            XCTAssertTrue(instance.primary.panel === panel)
            XCTAssertEqual(panel.frame, below)
        }
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

        manager.setHiddenBarJoin(.init(monitorId: monitor.id, edge: .below))
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

    func testIslandMenusOpenAwayFromTheNearestScreenEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let cases: [(CGRect, PopupAttachment.Edge)] = [
            (CGRect(x: 24, y: 1018, width: 32, height: 54), .below),
            (CGRect(x: 900, y: 8, width: 40, height: 40), .above),
            (CGRect(x: 4, y: 500, width: 54, height: 32), .right),
            (CGRect(x: 1862, y: 500, width: 54, height: 32), .left)
        ]
        for (frame, edge) in cases {
            XCTAssertEqual(PopupAttachment.Edge.away(from: frame, in: screen), edge, "\(frame)")
        }
    }

    func testAutoHideReusesHiddenPanelsAndRetainsPopupAndDragInteractions() throws {
        controller.settings.workspaceBar.autoHide = true
        let manager = makeManager()
        let popup = NSPanel(
            contentRect: CGRect(x: monitor.frame.midX - 50, y: monitor.frame.midY - 50, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer {
            popup.orderOut(nil)
            OwnedWindowRegistry.shared.unregister(surfaceId: "test-popup")
            manager.cleanup()
        }
        var pointer = monitor.frame.center
        controller.currentMouseLocation = { pointer }
        var bar = barSurface(itemCount: 1)
        bar.snapshot = snapshot(itemCount: 1)
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
        OwnedWindowRegistry.shared.register(
            popup,
            surfaceId: "test-popup",
            policy: SurfacePolicy(
                kind: .statusPanel,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        popup.orderFrontRegardless()
        manager.refreshAutoHide()
        pointer = monitor.frame.center
        manager.handleAutoHideMouseMoved(at: pointer)
        applyVisibility()
        XCTAssertTrue(panel.isVisible)

        popup.orderOut(nil)
        OwnedWindowRegistry.shared.unregister(surfaceId: "test-popup")
        manager.refreshAutoHide()
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

    func testShowLabelsChangesPublishWorkspaceBarEvents() {
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        func scene() -> DesiredSurfaceScene {
            var scene = DesiredSurfaceScene()
            scene.bars = WorldView(controller: controller).barSurfaces()
            return scene
        }
        let before = scene()
        XCTAssertFalse(before.bars.isEmpty)
        controller.settings.workspaceBar.showLabels.toggle()
        XCTAssertEqual(
            WMController.workspaceDataChannels(from: before, to: scene()),
            [.workspaceBar, .windowsChanged, .layoutChanged]
        )
    }

    func testRevealAndFullscreenVisibilityLeaveTheMenuBarHoldAlone() throws {
        controller.settings.workspaceBar.fullWidth = true
        controller.settings.workspaceBar.autoHide = true
        controller.settings.workspaceBar.revealModifier = .option
        controller.settings.workspaceBar.hideInNativeFullscreen = true
        let shell = ShellWidgetHost.shellDirectory(in: controller.settings.settingsFileURL.deletingLastPathComponent())
        XCTAssertTrue(try ShellProfiles.setValue(
            WorkspaceBarPosition.overlappingMenuBar.rawValue,
            at: ShellProfiles.key("workspaceBar", of: "default") + ["position"], in: shell
        ))
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let menuBar = FakeMenuBarAutohide()
        let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let manager = controller.workspaceBarManager
        manager.menuBarHold = MenuBarAutohideHold(
            system: menuBar.system,
            runtimeState: RuntimeStateStore(directory: state, deferSaves: false)
        )
        manager.setup(controller: controller, settings: controller.settings)
        defer { manager.cleanup() }
        func apply() {
            var bar = barSurface(itemCount: 1)
            bar.visible = controller.isWorkspaceBarVisible(on: monitor)
            manager.apply([bar])
        }

        apply()
        XCTAssertFalse(controller.isWorkspaceBarVisible(on: monitor))
        controller.setWorkspaceBarRevealHeld(true)
        apply()
        controller.setWorkspaceBarRevealHeld(false)
        apply()
        controller.workspaceManager.commitSpaceTopology(SpaceTopology(
            displays: [.init(displayIdentifier: String(monitor.displayId), spaceIds: [1], currentSpaceId: 1)],
            activeSpaceId: 1, fullscreenSpaceIds: [1], windowSpace: [:]
        ))
        controller.setWorkspaceBarRevealHeld(true)
        apply()
        XCTAssertFalse(controller.isWorkspaceBarVisible(on: monitor))
        XCTAssertEqual(menuBar.calls, [true])

        XCTAssertTrue(controller.toggleWorkspaceBarVisibility())
        apply()
        XCTAssertEqual(menuBar.calls, [true, false])
        XCTAssertTrue(controller.toggleWorkspaceBarVisibility())
        apply()
        XCTAssertTrue(try ShellProfiles.setValue(
            false, at: ShellProfiles.key("workspaceBar", of: "default") + ["fullWidth"], in: shell
        ))
        try XCTUnwrap(manager.shellHost).reloadConfig()
        XCTAssertFalse(controller.settings.workspaceBar.resolved(for: monitor).fullWidth)
        apply()
        XCTAssertEqual(menuBar.calls, [true, false, true, false])
    }

    func testAutoHideAndModifierRevealKeepOtherMonitorVisible() throws {
        let external = Monitor(
            id: .init(displayId: 92_201), displayId: 92_201,
            frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1055),
            hasNotch: false, name: "External"
        )
        controller.settings.workspaceBar.autoHide = false
        controller.settings.workspaceBar.revealModifier = .controlShift
        controller.settings.workspaceBar.update(
            MonitorBarSettings(monitorName: monitor.name, autoHide: true), for: monitor
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor, external])
        var pointer = monitor.frame.center
        controller.currentMouseLocation = { pointer }
        let manager = controller.workspaceBarManager
        manager.setup(controller: controller, settings: controller.settings)
        manager.panelFactory = { WorkspaceBarPanel.defaultPanel() }
        manager.frameApplier = { _, _ in }
        defer { manager.cleanup() }
        func apply() {
            manager.apply(WorldView(controller: controller).barSurfaces())
        }

        apply()
        let hiddenPanel = try XCTUnwrap(manager.barsByMonitor[monitor.id]?.primary.panel)
        let visiblePanel = try XCTUnwrap(manager.barsByMonitor[external.id]?.primary.panel)
        hiddenPanel.setFrame(CGRect(x: 100, y: monitor.frame.maxY - 24, width: 200, height: 24), display: false)
        manager.rebuildAutoHideTargets()
        XCTAssertFalse(hiddenPanel.isVisible)
        XCTAssertTrue(visiblePanel.isVisible)
        for held in [true, false] {
            controller.setWorkspaceBarRevealHeld(held)
            apply()
            XCTAssertEqual(hiddenPanel.isVisible, held)
            XCTAssertTrue(visiblePanel.isVisible)
        }

        pointer = CGPoint(x: hiddenPanel.frame.midX, y: monitor.frame.maxY - 0.5)
        manager.handleAutoHideMouseMoved(at: pointer)
        apply()
        XCTAssertTrue(hiddenPanel.isVisible)
        XCTAssertTrue(visiblePanel.isVisible)
        pointer = monitor.frame.center
        manager.handleAutoHideMouseMoved(at: pointer)
        apply()
        XCTAssertFalse(hiddenPanel.isVisible)
        XCTAssertTrue(visiblePanel.isVisible)
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

    func testAutoHideRevealDelayWaitsWhileThePointerRestsAtTheEdge() async throws {
        var pointer = monitor.frame.center
        let manager = try autoHidingManager { pointer }
        let sleepEntries = (0 ..< 1).map { XCTestExpectation(description: "Auto-hide sleep \($0) entered") }
        let sleeps = WorkspaceBarSleepProbe(entries: sleepEntries)
        defer {
            manager.cleanup()
            sleeps.resumeAll()
        }
        manager.autoHideDelays.sleep = { duration in await sleeps.sleep(duration) }
        controller.settings.workspaceBar.autoHideRevealDelayMilliseconds = 300

        pointer = Self.edgePoint
        manager.handleAutoHideMouseMoved(at: pointer)
        await fulfillment(of: [sleepEntries[0]], timeout: 2)
        XCTAssertEqual(sleeps.requestedDurations.last, .milliseconds(300))
        manager.handleAutoHideMouseMoved(at: pointer)

        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))
        try sleeps.resumeNext()
        try await waitUntil { manager.isPointerRevealed(on: monitor.id) }
        XCTAssertTrue(manager.isPointerRevealed(on: monitor.id))
        XCTAssertTrue(sleeps.isEmpty)
    }

    func testAutoHideRevealDelayIsCancelledWhenThePointerLeavesTheEdge() async throws {
        var pointer = monitor.frame.center
        let manager = try autoHidingManager { pointer }
        let sleepEntries = (0 ..< 1).map { XCTestExpectation(description: "Auto-hide sleep \($0) entered") }
        let sleeps = WorkspaceBarSleepProbe(entries: sleepEntries)
        defer {
            manager.cleanup()
            sleeps.resumeAll()
        }
        manager.autoHideDelays.sleep = { duration in await sleeps.sleep(duration) }
        controller.settings.workspaceBar.autoHideRevealDelayMilliseconds = 300
        pointer = Self.edgePoint
        manager.handleAutoHideMouseMoved(at: pointer)
        await fulfillment(of: [sleepEntries[0]], timeout: 2)
        XCTAssertEqual(sleeps.requestedDurations.last, .milliseconds(300))

        pointer = monitor.frame.center
        manager.handleAutoHideMouseMoved(at: pointer)
        try sleeps.resumeNext()
        await settle()

        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))
        XCTAssertTrue(manager.autoHideDelays.pendingIds.isEmpty)
    }

    func testAutoHideRevealDelaySkipsABarAlreadyShownByTheModifier() throws {
        let manager = try autoHidingManager { Self.retentionPoint }
        defer { manager.cleanup() }
        controller.settings.workspaceBar.autoHideRevealDelayMilliseconds = 300
        manager.autoHideTargets[0].isVisible = true

        manager.handleAutoHideMouseMoved(at: Self.retentionPoint)

        XCTAssertTrue(manager.isPointerRevealed(on: monitor.id))
        XCTAssertTrue(manager.autoHideDelays.pendingIds.isEmpty)
    }

    func testAutoHideHideDelayKeepsTheBarAndReturningToItCancelsTheHide() async throws {
        var pointer = Self.edgePoint
        let manager = try autoHidingManager { pointer }
        let sleepEntries = (0 ..< 2).map { XCTestExpectation(description: "Auto-hide sleep \($0) entered") }
        let sleeps = WorkspaceBarSleepProbe(entries: sleepEntries)
        defer {
            manager.cleanup()
            sleeps.resumeAll()
        }
        manager.autoHideDelays.sleep = { duration in await sleeps.sleep(duration) }
        controller.settings.workspaceBar.autoHideHideDelayMilliseconds = 300
        manager.handleAutoHideMouseMoved(at: pointer)
        XCTAssertTrue(manager.isPointerRevealed(on: monitor.id))

        pointer = monitor.frame.center
        manager.handleAutoHideMouseMoved(at: pointer)
        await fulfillment(of: [sleepEntries[0]], timeout: 2)
        XCTAssertEqual(sleeps.requestedDurations.last, .milliseconds(300))
        XCTAssertTrue(manager.isPointerRevealed(on: monitor.id))
        pointer = Self.retentionPoint
        manager.handleAutoHideMouseMoved(at: pointer)
        try sleeps.resumeNext()
        await settle()
        XCTAssertTrue(manager.isPointerRevealed(on: monitor.id))

        pointer = monitor.frame.center
        manager.handleAutoHideMouseMoved(at: pointer)
        await fulfillment(of: [sleepEntries[1]], timeout: 2)
        XCTAssertEqual(sleeps.requestedDurations.last, .milliseconds(300))
        try sleeps.resumeNext()
        try await waitUntil { !manager.isPointerRevealed(on: monitor.id) }
        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))
    }

    func testRemovingTheLastAutoHideTargetRestartsAPendingRevealDelay() async throws {
        var pointer = monitor.frame.center
        let manager = try autoHidingManager { pointer }
        let sleepEntries = (0 ..< 2).map { XCTestExpectation(description: "Auto-hide sleep \($0) entered") }
        let sleeps = WorkspaceBarSleepProbe(entries: sleepEntries)
        defer {
            manager.cleanup()
            sleeps.resumeAll()
        }
        manager.autoHideDelays.sleep = { duration in await sleeps.sleep(duration) }
        controller.settings.workspaceBar.autoHideRevealDelayMilliseconds = 300
        pointer = Self.edgePoint
        manager.handleAutoHideMouseMoved(at: pointer)
        await fulfillment(of: [sleepEntries[0]], timeout: 2)
        XCTAssertEqual(sleeps.requestedDurations.last, .milliseconds(300))
        let hiddenBar = DesiredBarSurface(
            monitor: monitor,
            visible: false,
            snapshot: snapshot(itemCount: 1),
            retainWhileHidden: true
        )

        controller.settings.workspaceBar.autoHide = false
        manager.apply([hiddenBar])
        XCTAssertTrue(manager.autoHideDelays.pendingIds.isEmpty)

        controller.settings.workspaceBar.autoHide = true
        manager.apply([hiddenBar])
        await fulfillment(of: [sleepEntries[1]], timeout: 2)
        XCTAssertEqual(sleeps.requestedDurations.last, .milliseconds(300))
        XCTAssertEqual(sleeps.count, 2)
        try sleeps.resumeNext()
        await settle()
        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))

        try sleeps.resumeNext()
        try await waitUntil { manager.isPointerRevealed(on: monitor.id) }
        XCTAssertTrue(manager.isPointerRevealed(on: monitor.id))
    }

    func testTurningAutoHideOffHidesImmediatelyDespiteTheHideDelay() throws {
        let pointer = Self.edgePoint
        let manager = try autoHidingManager { pointer }
        defer { manager.cleanup() }
        controller.settings.workspaceBar.autoHideHideDelayMilliseconds = 300
        manager.handleAutoHideMouseMoved(at: pointer)
        XCTAssertTrue(manager.isPointerRevealed(on: monitor.id))

        controller.settings.workspaceBar.autoHide = false
        manager.apply([DesiredBarSurface(monitor: monitor, visible: true, snapshot: snapshot(itemCount: 1))])

        XCTAssertFalse(manager.isPointerRevealed(on: monitor.id))
        XCTAssertTrue(manager.autoHideDelays.pendingIds.isEmpty)
    }

    private static let edgePoint = CGPoint(x: 200, y: 1079.5)
    private static let retentionPoint = CGPoint(x: 500, y: 1070)

    private func autoHidingManager(pointer: @escaping () -> CGPoint) throws -> WorkspaceBarManager {
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.currentMouseLocation = pointer
        controller.settings.workspaceBar.autoHide = true
        let manager = makeManager()
        manager.apply([
            DesiredBarSurface(
                monitor: monitor,
                visible: false,
                snapshot: snapshot(itemCount: 1),
                retainWhileHidden: true
            )
        ])
        let panel = try XCTUnwrap(manager.barsByMonitor[monitor.id]?.primary.panel)
        panel.setFrame(
            CGRect(x: monitor.frame.minX + 100, y: monitor.frame.maxY - 24, width: 200, height: 24),
            display: false
        )
        manager.rebuildAutoHideTargets()
        return manager
    }

    private enum AutoHideFixtureError: Error {
        case conditionNotReached
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition(), clock.now < deadline {
            try Task.checkCancellation()
            await Task.yield()
        }
        guard condition() else { throw AutoHideFixtureError.conditionNotReached }
    }

    private func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    private func makeManager() -> WorkspaceBarManager {
        let manager = WorkspaceBarManager(
            configDirectory: controller.settings.settingsFileURL.deletingLastPathComponent(),
            motionPolicy: MotionPolicy(animationsEnabled: false)
        )
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
            backgroundOpacity: 0.6,
            barHeight: 24
        )
    }
}

@MainActor
private final class WorkspaceBarSleepProbe {
    private let entries: [XCTestExpectation]
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var requestedDurations: [Duration] = []

    init(entries: [XCTestExpectation]) {
        self.entries = entries
    }

    var count: Int {
        pending.count
    }

    var isEmpty: Bool {
        pending.isEmpty
    }

    func sleep(_ duration: Duration) async {
        let index = requestedDurations.count
        requestedDurations.append(duration)
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                pending.append(continuation)
            }
            if index < entries.count {
                entries[index].fulfill()
            } else {
                XCTFail("Unexpected auto-hide sleep")
            }
        }
    }

    func resumeNext() throws {
        let continuation = try XCTUnwrap(pending.first, "Expected a pending auto-hide delay")
        pending.removeFirst()
        continuation.resume()
    }

    func resumeAll() {
        released = true
        let continuations = pending
        pending.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
