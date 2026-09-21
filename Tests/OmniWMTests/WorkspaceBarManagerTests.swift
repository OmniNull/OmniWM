// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
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

    func testPrimaryBarFramesChangedCallbackFiresWhenFrameChanges() {
        let manager = makeManager()
        var calls = 0
        manager.onPrimaryBarFramesChanged = { calls += 1 }

        manager.apply([barSurface(itemCount: 1)])
        XCTAssertEqual(calls, 1)

        manager.apply([barSurface(itemCount: 4)])
        XCTAssertEqual(calls, 2)
    }

    func testPrimaryBarFramesChangedCallbackDoesNotFireForIdenticalScene() {
        let manager = makeManager()
        var calls = 0
        manager.onPrimaryBarFramesChanged = { calls += 1 }

        let scene = [barSurface(itemCount: 2)]
        manager.apply(scene)
        XCTAssertEqual(calls, 1)

        manager.apply(scene)
        XCTAssertEqual(calls, 1)
    }

    func testPrimaryBarFramesChangedCallbackFiresWhenBarRemoved() {
        let manager = makeManager()
        var calls = 0
        manager.onPrimaryBarFramesChanged = { calls += 1 }

        manager.apply([barSurface(itemCount: 1)])
        XCTAssertEqual(calls, 1)

        manager.apply([])
        XCTAssertEqual(calls, 2)
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
