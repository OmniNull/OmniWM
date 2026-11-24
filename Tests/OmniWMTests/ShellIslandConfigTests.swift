// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellIslandConfigTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try write("return { profile = \"look\" }\n", to: "shell.luau")
        try write("return { leading = {} }\n", to: "default/shell.luau")
        try write("return { trailing = {} }\n", to: "look/shell.luau")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAbsentIslandDoesNotCreateSurfaceAndEmptyTableUsesDefaults() throws {
        var problems: [String] = []
        XCTAssertNil(try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems)).island)
        XCTAssertTrue(problems.isEmpty)

        try write("return { island = {} }\n", to: "look/shell.luau")
        XCTAssertEqual(
            try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems)).island,
            ShellIslandConfig()
        )
        XCTAssertTrue(problems.isEmpty)
    }

    func testUserProfileIslandOverridesMergeWithSelectedAndDefaultProfiles() throws {
        try write("return { island = { root = \"base\", width = 700, height = 200 } }\n", to: "default/shell.luau")
        try write("return { island = { root = \"custom\", height = 280 } }\n", to: "look/shell.luau")
        try write("""
        return {
            profile = "look",
            profiles = { look = { island = { width = 900, displays = "all", fullscreen = "show" } } },
        }
        """, to: "shell.luau")
        var problems: [String] = []
        let island = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems)?.island)
        XCTAssertEqual(island.root, "custom")
        XCTAssertEqual(island.size, CGSize(width: 900, height: 280))
        XCTAssertEqual(island.displays, .all)
        XCTAssertEqual(island.fullscreen, .show)
        XCTAssertTrue(problems.isEmpty)
    }

    func testDisplaySizingIsOptInAndValidated() throws {
        try write("return { island = { sizing = \"display\" } }\n", to: "look/shell.luau")
        var problems: [String] = []
        XCTAssertEqual(ShellConfig.load(shellDirectory: root, problems: &problems)?.island?.sizing, .display)
        XCTAssertTrue(problems.isEmpty)
        try write("return { island = { sizing = \"monitor-name\" } }\n", to: "look/shell.luau")
        problems = []
        XCTAssertNil(ShellConfig.load(shellDirectory: root, problems: &problems)?.island)
        XCTAssertTrue(problems.contains { $0.contains("sizing") })
    }

    func testInvalidIslandValuesFailClosedWithDiagnostics() throws {
        let size = "must be a finite number between 1 and 8192"
        for (value, expected) in [
            ("7", "island must be a table"),
            ("{ root = '../escape' }", "island.root must be a widget name"),
            ("{ displays = 'primary' }", "island.displays must be notch, main or all"),
            ("{ fullscreen = 'sometimes' }", "island.fullscreen must be hide or show"),
            ("{ width = 0 }", "island.width \(size)"),
            ("{ height = 8193 }", "island.height \(size)"),
            ("{ width = 0/0 }", "island.width \(size)"),
            ("{ height = '300' }", "island.height \(size)"),
            (
                "{ components = { { id = 'clock', widget = 'clock', enabled = 'yes' } } }",
                "island.components[1].enabled must be boolean"
            )
        ] {
            try write("return { island = \(value) }", to: "look/shell.luau")
            var problems: [String] = []
            let config = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems), value)
            XCTAssertNil(config.island, value)
            XCTAssertEqual(problems, ["shell.luau: \(expected)"], value)
        }
    }

    func testUnknownIslandKeyIsReportedAndUserTopLevelDoesNotEnableIsland() throws {
        try write("return { island = { extra = true } }\n", to: "look/shell.luau")
        var problems: [String] = []
        XCTAssertNotNil(ShellConfig.load(shellDirectory: root, problems: &problems)?.island)
        XCTAssertEqual(problems, ["shell.luau: island.extra is an unknown key"])

        try write("return { trailing = {} }\n", to: "look/shell.luau")
        try write("return { profile = \"look\", island = { root = \"custom\" } }\n", to: "shell.luau")
        problems = []
        XCTAssertNil(ShellConfig.load(shellDirectory: root, problems: &problems)?.island)
        XCTAssertTrue(problems.contains { $0.contains("island belongs in profiles[\"look\"]") })
    }

    func testComponentArraysReplaceAndProviderIsAnOrdinaryOption() throws {
        try write("""
        return {
            island = {
                components = {
                    {
                        id = "stock",
                        widget = "clock",
                        provider = true,
                        capabilities = { commands = { "session" } },
                    },
                },
            },
        }
        """, to: "look/shell.luau")
        var problems: [String] = []
        var config = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems))
        XCTAssertEqual(config.island?.components.count, 1)
        XCTAssertEqual(config.island?.components.first?.options["provider"], .bool(true))
        XCTAssertNil(config.island?.components.first?.capabilities)
        try write("""
        return {
            profile = "look",
            profiles = {
                look = {
                    island = {
                        components = {
                            {
                                id = "tokyo",
                                widget = "clock",
                                zone = "Asia/Tokyo",
                                provider = true,
                                capabilities = { commands = { "media" } },
                            },
                            { id = "london", widget = "clock", enabled = false },
                        },
                    },
                },
            },
        }
        """, to: "shell.luau")
        config = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems))
        XCTAssertEqual(config.island?.components.map(\.id), ["tokyo", "london"])
        XCTAssertEqual(config.island?.components.first?.options["provider"], .bool(true))
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
