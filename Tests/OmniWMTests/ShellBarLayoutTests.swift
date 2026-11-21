// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import TOML
import XCTest

final class ShellBarLayoutTests: XCTestCase {
    private var shell: URL!

    override func setUpWithError() throws {
        shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("shell", isDirectory: true)
        for path in [
            "default/widgets/clock",
            "default/widgets/workspaces",
            "default/widgets/hidden-bar",
            "default/widgets/weather",
            "widgets/mine"
        ] {
            let folder = shell.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("function render(ctx) return ui.box{} end\n".utf8)
                .write(to: folder.appendingPathComponent("init.luau"))
        }
        try write("default/shell.toml", """
        leading = ["workspaces"]
        trailing = ["clock"]
        hiddenBarWidget = "hidden-bar"
        """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: shell.deletingLastPathComponent())
    }

    private func write(_ path: String, _ contents: String) throws {
        try Data((contents + "\n").utf8).write(to: shell.appendingPathComponent(path))
    }

    private func read() throws -> String {
        try String(contentsOf: shell.appendingPathComponent("shell.toml"), encoding: .utf8)
    }

    private func parsed() throws -> [String: TOMLNode] {
        try TOMLDecoder().decode([String: TOMLNode].self, from: Data(read().utf8))
    }

    func testPriorityLayersLikeTheLanesAndUnlistedWidgetsRankOuterFirst() throws {
        try write("default/shell.toml", """
        leading = ["omniwm", "workspaces", "scratchpads"]
        center = ["active-window"]
        trailing = ["media", "clock"]
        priority = ["active-window"]
        """)
        func ranks(_ order: [String]) -> [String: Int] {
            Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        }
        var config = ShellConfig.resolve(shellDirectory: shell)
        XCTAssertEqual(config.priority, ["active-window"])
        XCTAssertEqual(
            config.priorityRanks(),
            ranks(["active-window", "omniwm", "clock", "workspaces", "media", "scratchpads"])
        )

        try write("shell.toml", """
        [profiles.default]
        priority = ["clock", "workspaces"]
        """)
        config = ShellConfig.resolve(shellDirectory: shell)
        XCTAssertEqual(config.priority, ["clock", "workspaces"])
        XCTAssertEqual(
            config.priorityRanks(),
            ranks(["clock", "workspaces", "omniwm", "media", "scratchpads", "active-window"])
        )
    }

    func testEnablingStatsPlacesTheConfiguredWidgetAndDisablingKeepsItsPosition() throws {
        try write("default/shell.toml", """
        leading = ["workspaces"]
        trailing = ["clock"]
        systemStatsWidget = "weather"
        """)
        XCTAssertTrue(try ShellBarLayout.setSystemStatsEnabled(true, in: shell))
        var config = ShellConfig.resolve(shellDirectory: shell)
        XCTAssertEqual(config.trailing, ["clock", "weather"])
        XCTAssertEqual(config.barOverride?.systemStatsButton, true)
        XCTAssertFalse(try ShellBarLayout.setSystemStatsEnabled(true, in: shell))
        XCTAssertTrue(try ShellBarLayout.edit(shellDirectory: shell) { $0.move("weather", to: .center) })
        XCTAssertTrue(try ShellBarLayout.setSystemStatsEnabled(false, in: shell))
        config = ShellConfig.resolve(shellDirectory: shell)
        XCTAssertEqual(config.center, ["weather"])
        XCTAssertEqual(config.barOverride?.systemStatsButton, false)
        XCTAssertTrue(try ShellBarLayout.setSystemStatsEnabled(true, in: shell))
        config = ShellConfig.resolve(shellDirectory: shell)
        XCTAssertEqual(config.center, ["weather"])
        XCTAssertEqual(config.trailing, ["clock"])
    }

    func testAnIslandThatDrawsStatsKeepsTheToggleOutOfTheBarLanes() throws {
        try write("default/shell.toml", """
        leading = ["workspaces"]
        trailing = ["clock"]
        systemStatsWidget = "weather"

        [island]
        root = "mine"
        drawsSystemStats = true
        """)
        XCTAssertTrue(ShellConfig.resolve(shellDirectory: shell).hasSystemStatsButtonPlace)
        XCTAssertTrue(try ShellBarLayout.setSystemStatsEnabled(true, in: shell))
        let config = ShellConfig.resolve(shellDirectory: shell)
        XCTAssertEqual(config.trailing, ["clock"])
        XCTAssertEqual(config.barOverride?.systemStatsButton, true)
    }

    func testTheLayoutShowsWhatTheBarShowsAndWhatCanBeAdded() throws {
        let layout = try ShellBarLayout.load(shellDirectory: shell).get()
        XCTAssertEqual(layout.leading, ["workspaces"])
        XCTAssertEqual(layout.trailing, ["clock"])
        XCTAssertFalse(layout.customized)
        XCTAssertEqual(layout.profile, ShellDefaults.profile)
        XCTAssertEqual(layout.source(of: "mine"), .yours)
        XCTAssertEqual(layout.source(of: "clock"), .builtIn)
        XCTAssertNil(layout.source(of: "hidden-bar"))
        XCTAssertEqual(layout.addable.map(\.name), ["mine", "weather"])
        XCTAssertNil(ShellConfig.resolve(shellDirectory: shell).barLane(of: "mine"))
        XCTAssertEqual(ShellBarLayout.title(of: "system-stats"), "System Stats")
        XCTAssertEqual(ShellBarLayout.title(of: "fx-lab"), "FX Lab")
        XCTAssertEqual(ShellBarLayout.title(of: "omniwm"), "OmniWM")
    }

    func testEditsMoveAddAndRemoveWidgets() throws {
        var layout = try ShellBarLayout.load(shellDirectory: shell).get()
        layout.add("mine", to: .trailing)
        layout.add("weather", to: .leading, at: 0)
        XCTAssertEqual(layout.leading, ["weather", "workspaces"])
        layout.move(in: .trailing, from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(layout.trailing, ["mine", "clock"])
        layout.shift("clock", by: -1)
        XCTAssertEqual(layout.trailing, ["clock", "mine"])
        layout.shift("clock", by: -1)
        XCTAssertEqual(layout.trailing, ["clock", "mine"])
        layout.move("clock", to: .leading)
        XCTAssertEqual(layout.leading, ["weather", "workspaces", "clock"])
        XCTAssertEqual(layout.trailing, ["mine"])
        layout.move("workspaces", to: .trailing)
        XCTAssertEqual(layout.trailing, ["workspaces", "mine"])
        layout.move("clock", to: .center)
        layout.move("weather", to: .center)
        XCTAssertEqual(layout.center, ["weather", "clock"])
        XCTAssertEqual(layout.lane(of: "clock"), .center)
        layout.move("clock", to: .trailing)
        XCTAssertEqual(layout.trailing, ["clock", "workspaces", "mine"])
        layout.move("clock", to: .center)
        layout.remove("mine")
        layout.remove("weather")
        XCTAssertEqual(Set(layout.addable.map(\.name)), ["weather", "mine"])
        layout.add("mine", to: .trailing)
        XCTAssertEqual(layout.trailing, ["workspaces", "mine"])
    }

    func testTheCenterLaneLoadsAndPlacesBetweenTheOthers() throws {
        try write("shell.toml", "profiles.default.center = [\"weather\"]")
        let config = ShellConfig.resolve(shellDirectory: shell)
        XCTAssertEqual(config.center, ["weather"])
        XCTAssertEqual(config.lane(of: "weather").lane, .center)
        XCTAssertEqual(config.lane(of: "clock").lane, .trailing)
        let layout = try ShellBarLayout.load(shellDirectory: shell).get()
        XCTAssertEqual(layout.center, ["weather"])
        XCTAssertTrue(layout.customized)
        XCTAssertEqual(layout.addable.map(\.name), ["mine"])
    }

    func testAHandWrittenProfileTableSupportsTheSameEditsAsDottedKeys() throws {
        let original = "[profiles.default]\ntrailing = [\"clock\"]\n"
        try write("shell.toml", original.trimmingCharacters(in: .newlines))
        XCTAssertEqual(try ShellBarLayout.load(shellDirectory: shell).get().trailing, ["clock"])
        XCTAssertTrue(try ShellBarLayout.edit(shellDirectory: shell) { $0.add("weather", to: .leading) })
        let saved = try ShellBarLayout.load(shellDirectory: shell).get()
        XCTAssertEqual(saved.leading, ["workspaces", "weather"])
        XCTAssertEqual(saved.trailing, ["clock"])
        XCTAssertTrue(saved.customized)
    }

    @MainActor
    func testSideLabelsFollowEachMonitorsResolvedPosition() {
        let monitors = [7, 8].map { id in
            Monitor(
                id: .init(displayId: CGDirectDisplayID(id)),
                displayId: CGDirectDisplayID(id),
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
                hasNotch: false,
                name: "Display \(id)"
            )
        }
        let settings = WorkspaceBarSettings()
        XCTAssertEqual(ShellBarLayout.vertical(settings, on: monitors), false)
        settings.update(
            MonitorBarSettings(monitorName: "Display 8", monitorDisplayId: 8, position: .left),
            for: monitors[1]
        )
        XCTAssertNil(ShellBarLayout.vertical(settings, on: monitors))
        XCTAssertEqual(
            ShellBarLayout.side(.leading, vertical: nil),
            "\(ShellBarLayout.side(.leading, vertical: false)) / \(ShellBarLayout.side(.leading, vertical: true))"
        )
        settings.profileOverride = WorkspaceBarProfileOverride(
            profile: "side",
            settings: MonitorBarSettings(monitorName: "", position: .right)
        )
        XCTAssertEqual(ShellBarLayout.vertical(settings, on: monitors), true)
        settings.update(
            MonitorBarSettings(monitorName: "Display 8", monitorDisplayId: 8, enabled: false),
            for: monitors[1]
        )
        settings.profileOverride = nil
        XCTAssertEqual(ShellBarLayout.vertical(settings, on: monitors), false)
    }

    func testProfileKeysAtTheTopLevelAreReportedWhereTheyBelong() throws {
        try write("shell.toml", "leading = [\"clock\"]\nbogus = 1\nprofiles.default.trailing = \"mine\"")
        var problems: [String] = []
        let config = ShellConfig.resolve(shellDirectory: shell, problems: &problems)
        XCTAssertEqual(config.leading, ["workspaces"])
        XCTAssertEqual(config.trailing, [])
        XCTAssertTrue(problems.contains { $0.contains("leading belongs in [profiles.default]") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("unknown key bogus") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("trailing must be a list of widget names") }, "\(problems)")
    }
}
