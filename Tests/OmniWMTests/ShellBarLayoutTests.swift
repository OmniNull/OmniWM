// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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

    func testSavingRewritesOnlyTheProfilesLayoutKeysAndResetRestoresTheProfile() throws {
        try write("shell.toml", """
        # my shell
        profile = "default"
        profiles.default.trailing = [
            "clock",
            "mine",
        ]

        [weather]
        city = "Toronto"
        """)
        var layout = try ShellBarLayout.load(shellDirectory: shell).get()
        XCTAssertTrue(layout.customized)
        XCTAssertEqual(layout.trailing, ["clock", "mine"])
        layout.remove("mine")
        layout.add("weather", to: .leading)
        try layout.save(shellDirectory: shell)
        XCTAssertEqual(try parsed(), [
            "profile": .string("default"),
            "profiles": .table(["default": .table([
                "leading": .array([.string("workspaces"), .string("weather")]),
                "center": .array([]),
                "trailing": .array([.string("clock")])
            ])]),
            "weather": .table(["city": .string("Toronto")])
        ])
        let saved = try ShellBarLayout.load(shellDirectory: shell).get()
        XCTAssertEqual(saved.leading, ["workspaces", "weather"])
        XCTAssertEqual(saved.trailing, ["clock"])

        try ShellBarLayout.reset(shellDirectory: shell)
        XCTAssertEqual(try parsed(), [
            "profile": .string("default"),
            "weather": .table(["city": .string("Toronto")])
        ])
        let reset = try ShellBarLayout.load(shellDirectory: shell).get()
        XCTAssertFalse(reset.customized)
        XCTAssertEqual(reset.trailing, ["clock"])
    }

    func testEachProfileKeepsItsOwnLayout() throws {
        try FileManager.default.createDirectory(
            at: shell.appendingPathComponent("styled", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write("styled/shell.toml", "leading = [\"clock\"]\ntrailing = []")
        try write("shell.toml", "profile = \"styled\"")
        XCTAssertTrue(try ShellBarLayout.edit(shellDirectory: shell) { $0.add("weather", to: .center) })
        XCTAssertEqual(try parsed(), [
            "profile": .string("styled"),
            "profiles": .table(["styled": .table([
                "leading": .array([.string("clock")]),
                "center": .array([.string("weather")]),
                "trailing": .array([])
            ])])
        ])
        let styled = try ShellBarLayout.load(shellDirectory: shell).get()
        XCTAssertEqual(styled.leading, ["clock"])
        XCTAssertEqual(styled.center, ["weather"])
        XCTAssertTrue(styled.customized)

        XCTAssertTrue(try ShellProfiles.select(ShellDefaults.profile, in: shell))
        let plain = try ShellBarLayout.load(shellDirectory: shell).get()
        XCTAssertEqual(plain.leading, ["workspaces"])
        XCTAssertEqual(plain.center, [])
        XCTAssertFalse(plain.customized)
        try ShellBarLayout.reset(shellDirectory: shell)
        XCTAssertTrue(try ShellProfiles.select("styled", in: shell))
        XCTAssertEqual(try ShellBarLayout.load(shellDirectory: shell).get().center, ["weather"])
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

    func testABrokenLayerBlocksEditingInsteadOfSavingFallbackLists() throws {
        try write("shell.toml", "profiles.default.leading = [\"clock\"]\nprofiles.default.theme = \"dusk\"")
        try write("default/shell.toml", "leading = [")
        guard case let .failure(unreadable) = ShellBarLayout.load(shellDirectory: shell) else {
            return XCTFail("a broken layer must not load")
        }
        XCTAssertTrue(unreadable.problem.hasPrefix("default/shell.toml"), unreadable.problem)
        XCTAssertThrowsError(try ShellBarLayout.edit(shellDirectory: shell) { $0.remove("clock") })
        XCTAssertEqual(try read(), "profiles.default.leading = [\"clock\"]\nprofiles.default.theme = \"dusk\"\n")
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

    func testAStaleDragIsCancelledAndOtherEditsKeepOutsideChanges() throws {
        try write("shell.toml", "profiles.default.trailing = [\"clock\", \"weather\", \"mine\"]")
        let shown = try ShellBarLayout.load(shellDirectory: shell).get()
        try write(
            "shell.toml",
            "profiles.default.trailing = [\"mine\", \"clock\"]\nprofiles.default.center = [\"weather\"]"
        )

        XCTAssertFalse(try ShellBarLayout.edit(shellDirectory: shell, unlessChanged: (.trailing, shown.trailing)) {
            $0.move(in: .trailing, from: [2], to: 0)
        })
        XCTAssertEqual(
            try read(),
            "profiles.default.trailing = [\"mine\", \"clock\"]\nprofiles.default.center = [\"weather\"]\n"
        )
        XCTAssertTrue(try ShellBarLayout.edit(shellDirectory: shell) { $0.remove("clock") })
        let saved = try ShellBarLayout.load(shellDirectory: shell).get()
        XCTAssertEqual(saved.center, ["weather"])
        XCTAssertEqual(saved.trailing, ["mine"])
        XCTAssertTrue(try ShellBarLayout.edit(shellDirectory: shell, unlessChanged: (.center, saved.center)) {
            $0.add("clock", to: .center)
        })
        XCTAssertEqual(try ShellBarLayout.load(shellDirectory: shell).get().center, ["weather", "clock"])
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
