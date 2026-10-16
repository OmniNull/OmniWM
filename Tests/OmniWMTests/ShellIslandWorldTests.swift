// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellIslandWorldTests: XCTestCase {
    func testIslandSurfacesRemainIndependentOfBarAndTrackFullscreenPerDisplay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = makeSettings(root)
        settings.workspaceBar.enabled = false
        let controller = WMController(settings: settings)
        let monitors = [makeMonitor(8101), makeMonitor(8102)]
        controller.workspaceManager.applyMonitorConfigurationChange(monitors)
        let world = WorldView(controller: controller)

        XCTAssertTrue(world.islandSurfaces().isEmpty)
        settings.island.enabled = true
        XCTAssertEqual(world.islandSurfaces(), monitors.map {
            DesiredIslandSurface(monitor: $0, fullscreen: false)
        })
        XCTAssertTrue(world.barSurfaces().isEmpty)

        controller.workspaceManager.commitSpaceTopology(SpaceTopology(
            displays: [
                .init(displayIdentifier: try XCTUnwrap(monitors[0].displayUUID), spaceIds: [1], currentSpaceId: 1),
                .init(displayIdentifier: try XCTUnwrap(monitors[1].displayUUID), spaceIds: [2], currentSpaceId: 2)
            ],
            activeSpaceId: 1,
            fullscreenSpaceIds: [1],
            windowSpace: [:]
        ))
        XCTAssertEqual(world.islandSurfaces(), [
            DesiredIslandSurface(monitor: monitors[0], fullscreen: true),
            DesiredIslandSurface(monitor: monitors[1], fullscreen: false)
        ])

        controller.hasStartedServices = true
        XCTAssertEqual(SurfaceDerivation.derive(world: world).islands, world.islandSurfaces())
        controller.hasStartedServices = false
        settings.island.enabled = false
        XCTAssertTrue(world.islandSurfaces().isEmpty)
    }

    func testIslandKeepsHostAcrossBarDisableAndBothDisabledStopIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = makeSettings(root)
        let shell = root.appendingPathComponent("shell", isDirectory: true)
        try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)
        try Data("profiles.default.leading = []\nprofiles.default.center = []\nprofiles.default.trailing = []\n".utf8)
            .write(to: shell.appendingPathComponent("shell.toml"))
        settings.workspaceBar.enabled = false
        settings.island.enabled = true
        let controller = WMController(settings: settings)
        let manager = controller.workspaceBarManager
        manager.setup(controller: controller, settings: settings)
        defer { manager.cleanup() }

        manager.prepareShell(for: [], settings: settings)
        let host = try XCTUnwrap(manager.shellHost)
        controller.setWorkspaceBarEnabled(false)
        XCTAssertTrue(manager.shellHost === host)

        settings.island.enabled = false
        manager.prepareShell(for: [], settings: settings)
        XCTAssertNil(manager.shellHost)
        XCTAssertTrue(manager.lastIslands.isEmpty)
    }

    private func makeMonitor(_ displayId: UInt32) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: CGFloat(displayId - 8101) * 1440, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: CGFloat(displayId - 8101) * 1440, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Island \(displayId)",
            displayUUID: "00000000-0000-0000-0000-00000000\(displayId)"
        )
    }

    private func makeSettings(_ root: URL) -> SettingsStore {
        SettingsStore(
            persistence: SettingsFilePersistence(directory: root, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: root, deferSaves: false),
            autosaveEnabled: false
        )
    }
}
