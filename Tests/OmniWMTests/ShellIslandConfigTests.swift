// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellIslandConfigTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try write("profile = \"look\"\n", to: "shell.toml")
        try write("leading = []\n", to: "default/shell.toml")
        try write("trailing = []\n", to: "look/shell.toml")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAbsentIslandDoesNotCreateSurfaceAndEmptyTableUsesDefaults() throws {
        var problems: [String] = []
        XCTAssertNil(try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems)).island)
        XCTAssertTrue(problems.isEmpty)

        try write("[island]\n", to: "look/shell.toml")
        XCTAssertEqual(
            try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems)).island,
            ShellIslandConfig()
        )
        XCTAssertTrue(problems.isEmpty)
    }

    func testUserProfileIslandOverridesMergeWithSelectedAndDefaultProfiles() throws {
        try write("[island]\nroot = \"base\"\nwidth = 700\nheight = 200\n", to: "default/shell.toml")
        try write("[island]\nroot = \"custom\"\nheight = 280\n", to: "look/shell.toml")
        try write("""
        profile = "look"
        [profiles.look.island]
        width = 900
        displays = "all"
        fullscreen = "show"
        """, to: "shell.toml")
        var problems: [String] = []
        let island = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems)?.island)
        XCTAssertEqual(island.root, "custom")
        XCTAssertEqual(island.size, CGSize(width: 900, height: 280))
        XCTAssertEqual(island.displays, .all)
        XCTAssertEqual(island.fullscreen, .show)
        XCTAssertTrue(problems.isEmpty)
    }

    func testInvalidIslandValuesFailClosedWithDiagnostics() throws {
        for value in [
            "island = 7", "[island]\nroot = \"../escape\"", "[island]\ndisplays = \"primary\"",
            "[island]\nfullscreen = \"sometimes\"", "[island]\nwidth = 0", "[island]\nheight = 8193",
            "[island]\nwidth = nan", "[island]\nheight = \"300\""
        ] {
            try write(value, to: "look/shell.toml")
            var problems: [String] = []
            let config = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems), value)
            XCTAssertNil(config.island, value)
            XCTAssertTrue(problems.contains { $0.contains("[island]") }, value)
        }
    }

    func testUnknownIslandKeyIsReportedAndUserTopLevelDoesNotEnableIsland() throws {
        try write("[island]\nextra = true\n", to: "look/shell.toml")
        var problems: [String] = []
        XCTAssertNotNil(ShellConfig.load(shellDirectory: root, problems: &problems)?.island)
        XCTAssertTrue(problems.contains { $0.contains("extra") })

        try write("trailing = []\n", to: "look/shell.toml")
        try write("profile = \"look\"\n[island]\nroot = \"custom\"\n", to: "shell.toml")
        problems = []
        XCTAssertNil(ShellConfig.load(shellDirectory: root, problems: &problems)?.island)
        XCTAssertTrue(problems.contains { $0.contains("island belongs in [profiles.look]") })
    }

    func testComponentArraysReplaceAndOnlyUserFileGrantsProviderConsent() throws {
        try write("""
        [island]
        [[island.components]]
        id = "stock"
        widget = "clock"
        provider = true
        capabilities = {commands = ["session"]}
        """, to: "look/shell.toml")
        var problems: [String] = []
        var config = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems))
        XCTAssertEqual(config.island?.components.count, 1)
        XCTAssertEqual(config.island?.components.first?.provider, false)
        XCTAssertNil(config.island?.components.first?.capabilities)
        try write("""
        profile = "look"
        [[profiles.look.island.components]]
        id = "tokyo"
        widget = "clock"
        zone = "Asia/Tokyo"
        provider = true
        capabilities = {commands = ["media"]}
        [[profiles.look.island.components]]
        id = "london"
        widget = "clock"
        enabled = false
        """, to: "shell.toml")
        config = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems))
        XCTAssertEqual(config.island?.components.map(\.id), ["tokyo", "london"])
        XCTAssertEqual(config.island?.components.first?.provider, true)
        XCTAssertEqual(config.island?.components.first?.capabilities?.commands, ["media"])
        XCTAssertEqual(config.island?.components.first?.options["zone"], .string("Asia/Tokyo"))
        XCTAssertEqual(config.island?.components.last?.enabled, false)
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    private func write(_ text: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
