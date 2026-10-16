// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellConfigurationApplicationTests: XCTestCase {
    func testPreparedLaneChangesRescanWithoutRereadingDiskAndPublishOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("shell")
        try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)
        try Data("broken = [".utf8).write(to: shell.appendingPathComponent("shell.toml"))
        var layoutChanges = 0
        let host = ShellWidgetHost(
            configDirectory: directory, resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] },
            onLayoutChange: { layoutChanges += 1 }, onCommand: { _, _ in }, onMenu: { _ in },
            onPreview: { _ in }, onDrag: { _ in }, onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        defer { host.stop() }
        host.started = true
        host.config.directories = [shell]
        host.config.leading = ["removed-widget"]
        var publications: [ShellConfig] = []
        host.onConfigChange = { publications.append($0) }
        var prepared = host.config
        prepared.leading = []
        host.applyConfig(prepared, problems: ["prepared warning"])
        XCTAssertEqual(host.config, prepared)
        XCTAssertEqual(host.configProblems, ["prepared warning"])
        XCTAssertEqual(publications, [prepared])
        XCTAssertEqual(layoutChanges, 1)
        host.applyConfig(prepared, problems: ["prepared warning"])
        XCTAssertEqual(publications, [prepared])
        XCTAssertEqual(layoutChanges, 1)
        var reports = 0
        host.onWidgetsChange = { reports += 1 }
        host.applyConfig(prepared, problems: ["updated warning"])
        XCTAssertEqual(host.configProblems, ["updated warning"])
        XCTAssertEqual(reports, 1)
        host.applyConfig(prepared, problems: ["updated warning"])
        XCTAssertEqual(reports, 1)
        host.applyConfig(prepared)
        XCTAssertTrue(host.configProblems.isEmpty)
        XCTAssertEqual(reports, 2)
        XCTAssertEqual(publications, [prepared])
        XCTAssertEqual(layoutChanges, 1)
    }

    func testCoordinatorSavePreservesPreparedWarningsInTheLiveHost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("shell")
        _ = ShellDefaults.sync(into: shell)
        try Data("unexpected = 1\n".utf8).write(to: shell.appendingPathComponent("shell.toml"))
        let motion = MotionPolicy(animationsEnabled: false)
        let manager = WorkspaceBarManager(configDirectory: directory, motionPolicy: motion)
        let host = ShellWidgetHost(
            configDirectory: directory, resources: ShellResources(motion: motion),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] },
            onLayoutChange: {}, onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in },
            onDrag: { _ in }, onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        manager.shellHost = host
        defer { manager.shellHost = nil
            host.stop()
        }
        let coordinator = manager.shellConfiguration
        try await coordinator.refresh()
        XCTAssertTrue(host.configProblems.contains { $0.contains("unexpected") })
        try await coordinator.set(49, key: "height")
        XCTAssertEqual(host.config, coordinator.config)
        XCTAssertEqual(host.configProblems, coordinator.configProblems)
        XCTAssertTrue(host.widgetReport.problems.contains { $0.contains("unexpected") })
    }
}
