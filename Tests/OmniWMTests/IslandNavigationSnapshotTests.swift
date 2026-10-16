// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class IslandNavigationSnapshotTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let main: Monitor
        let side: Monitor
        let first: WorkspaceDescriptor.ID
        let second: WorkspaceDescriptor.ID
        let third: WorkspaceDescriptor.ID
        let host: ShellWidgetHost
    }

    func testNavigationPreservesNiriColumnOrderSameAppWindowsAndFloatingTail() throws {
        let fixture = try makeFixture()
        let first = try addWindow(1, to: fixture.first, fixture: fixture)
        let second = try addWindow(2, to: fixture.first, fixture: fixture)
        let third = try addWindow(3, to: fixture.first, fixture: fixture)
        let floating = try addWindow(4, to: fixture.first, mode: .floating, fixture: fixture)
        _ = try addWindow(5, to: fixture.second, fixture: fixture)
        _ = try addWindow(6, to: fixture.third, fixture: fixture)
        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriStack(fixture.first, target: first.id, position: .after),
            source: .init(tokens: [second.id], workspaceId: fixture.first, isFloating: false)
        ))
        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriMoveColumn(fixture.first, oneBasedIndex: 1),
            source: .init(tokens: [third.id], workspaceId: fixture.first, isFloating: false)
        ))

        let snapshot = try navigation(on: fixture.main, fixture: fixture)

        XCTAssertEqual(snapshot.workspace, "1")
        XCTAssertEqual(snapshot.name, "Writing")
        XCTAssertEqual(snapshot.layout, "niri")
        XCTAssertEqual(snapshot.windows.map(\.token), [third.id, first.id, second.id, floating.id])
        XCTAssertEqual(snapshot.windows.map(\.column), [1, 2, 2, 0])
        XCTAssertEqual(Set(snapshot.windows.map(\.token.pid)), [730_000])
        XCTAssertTrue(WorldView(controller: fixture.controller).barSurfaces().isEmpty)
    }

    func testFocusedWindowUsesSelectionThenPerWorkspaceRememberedFocus() throws {
        let fixture = try makeFixture()
        let selected = try addWindow(11, to: fixture.first, fixture: fixture)
        let remembered = try addWindow(12, to: fixture.first, fixture: fixture)
        let side = try addWindow(13, to: fixture.third, fixture: fixture)
        let manager = fixture.controller.workspaceManager
        _ = manager.setManagedFocus(selected.id, in: fixture.first, onMonitor: fixture.main.id)
        _ = manager.rememberFocus(remembered.id, in: fixture.first)
        _ = manager.rememberFocus(side.id, in: fixture.third)

        XCTAssertEqual(try navigation(on: fixture.main, fixture: fixture).focused, selected.id)
        XCTAssertEqual(try navigation(on: fixture.side, fixture: fixture).focused, side.id)

        _ = manager.setManagedFocus(side.id, in: fixture.third, onMonitor: fixture.side.id)

        XCTAssertEqual(try navigation(on: fixture.main, fixture: fixture).focused, remembered.id)
    }

    func testWorkspaceSwitchProjectsOnlyTheNewWorkspaceIncludingEmptyAndDwindle() throws {
        let fixture = try makeFixture()
        _ = try addWindow(21, to: fixture.first, fixture: fixture)
        let manager = fixture.controller.workspaceManager
        XCTAssertTrue(manager.setActiveWorkspace(fixture.second, on: fixture.main.id))

        let empty = try navigation(on: fixture.main, fixture: fixture)

        XCTAssertEqual(empty.workspace, "2")
        XCTAssertEqual(empty.layout, "dwindle")
        XCTAssertTrue(empty.windows.isEmpty)
        XCTAssertNil(empty.focused)
        let window = try addWindow(22, to: fixture.second, fixture: fixture)
        _ = manager.setManagedFocus(window.id, in: fixture.second, onMonitor: fixture.main.id)
        let populated = try navigation(on: fixture.main, fixture: fixture)
        XCTAssertEqual(populated.windows.map(\.token), [window.id])
        XCTAssertEqual(populated.windows.map(\.column), [0])
        XCTAssertEqual(populated.focused, window.id)
    }

    func testNavigationRequiresEnabledIslandAndConfiguredMonitor() throws {
        let fixture = try makeFixture()
        let world = WorldView(controller: fixture.controller)
        fixture.controller.workspaceBarManager.shellHost = nil
        XCTAssertEqual(world.islandSurfaces().count, 2)
        XCTAssertTrue(world.islandSurfaces().allSatisfy { $0.navigation == nil })
        fixture.controller.workspaceBarManager.shellHost = fixture.host
        fixture.host.config.island = nil
        XCTAssertTrue(world.islandSurfaces().allSatisfy { $0.navigation == nil })
        fixture.host.config.island = ShellIslandConfig()
        let notchOnly = world.islandSurfaces()
        XCTAssertNotNil(notchOnly.first { $0.monitor.id == fixture.main.id }?.navigation)
        XCTAssertNil(notchOnly.first { $0.monitor.id == fixture.side.id }?.navigation)
        fixture.host.config.island?.displays = .all
        XCTAssertTrue(world.islandSurfaces().allSatisfy { $0.navigation != nil })
        fixture.controller.settings.island.enabled = false
        XCTAssertTrue(world.islandSurfaces().isEmpty)
    }

    func testShellEncodingUsesHostSessionForWindowAndFocusIDs() throws {
        let fixture = try makeFixture()
        let window = try addWindow(31, to: fixture.first, title: "Draft", fixture: fixture)
        _ = fixture.controller.workspaceManager.setManagedFocus(
            window.id, in: fixture.first, onMonitor: fixture.main.id
        )
        let placements = fixture.host.islandPlacements(WorldView(controller: fixture.controller).islandSurfaces())
        let surface = try XCTUnwrap(placements[ShellBarKey(monitor: fixture.main.id, placement: .island)]?.surface)
        var writer = ShellValueWriter()
        surface.write(to: &writer)
        let fields = try XCTUnwrap(ShellServiceValue.decode(writer.bytes).fields)
        let navigation = try XCTUnwrap(fields["navigation"]?.fields)
        let windows = try XCTUnwrap(navigation["windows"]?.values)
        let encoded = try XCTUnwrap(windows.first?.fields)
        let expected = IPCWindowOpaqueID.encode(
            pid: window.pid,
            windowId: window.windowId,
            sessionToken: "island-session"
        )

        XCTAssertEqual(navigation["workspace"]?.string, "1")
        XCTAssertEqual(navigation["name"]?.string, "Writing")
        XCTAssertEqual(navigation["layout"]?.string, "niri")
        XCTAssertEqual(navigation["focused"]?.string, expected)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(encoded["id"]?.string, expected)
        XCTAssertEqual(encoded["bundle"]?.string, "com.example.editor")
        XCTAssertEqual(encoded["title"]?.string, "Draft")
        XCTAssertEqual(encoded["column"]?.number, 1)
        XCTAssertFalse(fixture.controller.appInfoCache.hasCachedInfo(for: window.pid))
    }

    func testAbsentTitlesAndNavigationRemainEmptyAndNil() throws {
        let fixture = try makeFixture()
        _ = try addWindow(41, to: fixture.first, fixture: fixture)
        XCTAssertEqual(try navigation(on: fixture.main, fixture: fixture).windows.first?.title, "")
        let placements = fixture.host.islandPlacements([
            DesiredIslandSurface(monitor: fixture.main, fullscreen: false)
        ])
        let surface = try XCTUnwrap(placements.values.first?.surface)
        var writer = ShellValueWriter()
        surface.write(to: &writer)

        XCTAssertEqual(try ShellServiceValue.decode(writer.bytes).fields?["navigation"], .null)
    }

    private func navigation(on monitor: Monitor, fixture: Fixture) throws -> IslandNavigationSnapshot {
        try XCTUnwrap(WorldView(controller: fixture.controller).islandSurfaces()
            .first { $0.monitor.id == monitor.id }?.navigation)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IslandNavigationSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        let main = Monitor(
            id: .init(displayId: 730_001), displayId: 730_001,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 868),
            hasNotch: true, notchRange: 710 ... 890, notchHeight: 32, name: "Main"
        )
        let side = Monitor(
            id: .init(displayId: 730_002), displayId: 730_002,
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            hasNotch: false, name: "Side"
        )
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true), deferSaves: false
            ),
            autosaveEnabled: false
        )
        settings.animationsEnabled = false
        settings.workspaceBar.enabled = false
        settings.island.enabled = true
        settings.workspaces.defaultLayoutType = .niri
        settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1", displayName: "Writing", monitorAssignment: .specificDisplay(OutputId(from: main))
            ),
            WorkspaceConfiguration(
                name: "2", monitorAssignment: .specificDisplay(OutputId(from: main)), layoutType: .dwindle
            ),
            WorkspaceConfiguration(name: "3", monitorAssignment: .specificDisplay(OutputId(from: side)))
        ]
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in }, focusSpecificWindow: { _, _, _ in }, raiseWindow: { _ in }
            )
        )
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([main, side])
        manager.applySettings()
        let niri = NiriLayoutEngine()
        niri.animationClock = controller.animationClock
        controller.niriEngine = niri
        controller.niriLayoutHandler.syncMonitorsToNiriEngine()
        let dwindle = DwindleLayoutEngine()
        dwindle.animationClock = controller.animationClock
        controller.dwindleEngine = dwindle
        let first = try XCTUnwrap(manager.workspaceId(named: "1"))
        let second = try XCTUnwrap(manager.workspaceId(named: "2"))
        let third = try XCTUnwrap(manager.workspaceId(named: "3"))
        XCTAssertTrue(manager.setActiveWorkspace(third, on: side.id, updateInteractionMonitor: false))
        XCTAssertTrue(manager.setActiveWorkspace(first, on: main.id))
        let host = ShellWidgetHost(
            configDirectory: root.appendingPathComponent("config", isDirectory: true),
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            sessionToken: "island-session",
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        host.config.island = ShellIslandConfig()
        host.config.island?.displays = .all
        controller.workspaceBarManager.shellHost = host
        controller.layoutRefreshController.resetState()
        return Fixture(
            controller: controller,
            main: main,
            side: side,
            first: first,
            second: second,
            third: third,
            host: host
        )
    }

    private func addWindow(
        _ index: Int,
        to workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode = .tiling,
        title: String? = nil,
        fixture: Fixture
    ) throws -> WindowHandle {
        let pid: pid_t = 730_000
        let windowId = 730_100 + index
        let manager = fixture.controller.workspaceManager
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid, windowId: windowId, to: workspace, mode: mode,
            managedReplacementMetadata: ManagedReplacementMetadata(
                bundleId: "com.example.editor", workspaceId: workspace, mode: mode,
                role: nil, subrole: nil, title: title, windowLevel: nil, parentWindowId: nil, frame: nil
            )
        )
        if mode == .tiling {
            manager.withEngineMutationScope(in: workspace) {
                switch manager.activeLayoutKind(for: workspace) {
                case .niri:
                    _ = fixture.controller.niriEngine?.addWindow(token: token, to: workspace, afterSelection: nil)
                case .dwindle:
                    _ = fixture.controller.dwindleEngine?.addWindow(token: token, to: workspace, activeWindowFrame: nil)
                }
            }
        }
        return try XCTUnwrap(manager.handle(for: token))
    }
}
