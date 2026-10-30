// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class ShellRoomProfileTests: XCTestCase {
    private var root: URL!

    private static let rooms = """
    [island.room]
    setting = "layout"
    size = "barSize"
    [island.room.variants.island]
    top = { base = 8, scaled = 54, mode = "add" }
    dock = "bottom"
    [island.room.variants.left]
    left = { base = 14, scaled = 62.1, mode = "total" }
    top = { base = 24, mode = "total", clear = "none" }
    right = { base = 24, mode = "total" }
    bottom = { base = 24, mode = "total" }
    dock = "right"
    [island.room.variants.seg]
    top = { base = 10, scaled = 48.6, mode = "total" }
    left = { base = 24, mode = "total" }
    right = { base = 24, mode = "total" }
    bottom = { base = 24, mode = "total" }
    [island.room.dock]
    base = 23.8
    scaled = 45.9
    when = ["pins", "addons"]
    unless = "dockOverlap"
    """

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("default"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testVariantsResolveScaledPointValuesAndModes() throws {
        for (layout, size, edge, expected) in [
            ("island", 1.0, WorkspaceBarRoom.Edge.top, 62.0),
            ("island", 0.7, .top, 46.0),
            ("left", 1.0, .left, 76.0),
            ("seg", 1.0, .top, 59.0)
        ] {
            let (config, problems) = try load(settings: "layout='\(layout)'\nbarSize=\(size)")
            XCTAssertEqual(problems, [])
            let room = try XCTUnwrap(config.barOverride?.room)
            XCTAssertEqual(room.edges[edge]?.value, expected)
            XCTAssertEqual(room.edges[edge]?.mode, layout == "island" ? .add : .total)
            if layout == "left" || layout == "seg" {
                for other in WorkspaceBarRoom.Edge.allCases where other != edge {
                    XCTAssertEqual(room.edges[other]?.value, 24)
                }
            }
        }
    }

    func testMissingSizeSettingDefaultsToOneAndRoomKeepsOverridePresent() throws {
        let (config, problems) = try load()
        XCTAssertEqual(problems, [])
        let bar = try XCTUnwrap(config.barOverride)
        XCTAssertTrue(bar.settings.overriddenKeys.isEmpty)
        XCTAssertTrue(bar.overriddenKeys.contains("room"))
        XCTAssertEqual(bar.room?.edges[.top]?.value, 62)
    }

    func testMissingOptionalSizeKeyDefaultsToOne() throws {
        let rooms = Self.rooms.replacingOccurrences(of: "size = \"barSize\"\n", with: "")
        let (config, problems) = try load(settings: "layout='island'\nbarSize=0.7", rooms: rooms)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(config.barOverride?.room?.edges[.top]?.value, 62)
    }

    func testRoomUsesMergedRootSettingsAndDisplaySelectorInOverrideEquality() throws {
        let (initial, _) = try load()
        try Data("[profiles.default.widgets.root]\nlayout='left'\nbarSize=0.7\n".utf8)
            .write(to: root.appendingPathComponent("shell.toml"))
        var problems: [String] = []
        let overridden = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems))
        XCTAssertEqual(problems, [])
        XCTAssertEqual(overridden.barOverride?.room?.edges[.left]?.value, 57)
        XCTAssertNotEqual(overridden.barOverride, initial.barOverride)
        let (notch, notchProblems) = try load(displays: "notch")
        XCTAssertEqual(notchProblems, [])
        XCTAssertEqual(notch.barOverride?.room?.displays, .notch)
        XCTAssertNotEqual(notch.barOverride?.room, initial.barOverride?.room)
    }

    func testDockActivatesForAnyNonemptyListOrTrueAndHonoursUnless() throws {
        for (settings, active) in [
            ("pins=['app']", true), ("pins=[]\naddons=['clock']", true), ("pins=true", true),
            ("pins=[]\naddons=false", false), ("pins=['app']\ndockOverlap=true", false),
            ("pins=['app']\ndockOverlap=false", true)
        ] {
            let (config, problems) = try load(settings: "layout='left'\n\(settings)")
            XCTAssertEqual(problems, [])
            XCTAssertEqual(config.barOverride?.room?.dock?.edge, active ? .right : nil)
            XCTAssertEqual(config.barOverride?.room?.dock?.value, active ? 70 : nil)
        }
    }

    func testTopClearanceStaysMonitorRelative() throws {
        for clear in ["none", "notch", "menuBar"] {
            let rooms = Self.rooms.replacingOccurrences(
                of: "mode = \"add\"",
                with: "mode = \"add\", clear = \"\(clear)\""
            )
            let (config, problems) = try load(rooms: rooms)
            XCTAssertEqual(problems, [])
            let edge = try XCTUnwrap(config.barOverride?.room?.edges[.top])
            XCTAssertEqual(edge.clear.rawValue, clear)
            XCTAssertEqual(edge.value, 62)
        }
    }

    func testRoomSelectorIncludesTheSameDisplaysAsTheIsland() throws {
        let monitors = [
            monitor(id: 1, main: true, notch: false), monitor(id: 2, main: false, notch: true),
            monitor(id: 3, main: false, notch: false)
        ]
        for (selector, expected) in [
            ("all", [true, true, true]),
            ("main", [true, false, false]),
            ("notch", [false, true, false])
        ] {
            let (config, problems) = try load(displays: selector)
            XCTAssertEqual(problems, [])
            let room = try XCTUnwrap(config.barOverride?.room)
            XCTAssertEqual(monitors.map(room.includes), expected)
        }
    }

    func testUnknownVariantAndMissingOrInvalidRootSelectorReportNoRoom() throws {
        for settings in ["layout='missing'", "other='island'", "layout=3"] {
            let (config, problems) = try load(settings: settings)
            XCTAssertNil(config.barOverride?.room)
            XCTAssertTrue(problems.contains { $0.contains("[island.room]") })
        }
    }

    func testUnknownFieldsInRoomUnselectedVariantsEdgesAndDockRejectTheRoom() throws {
        for rooms in [
            Self.rooms.replacingOccurrences(of: "setting = \"layout\"", with: "setting = \"layout\"\nextra = true"),
            Self.rooms.replacingOccurrences(
                of: "[island.room.variants.left]",
                with: "[island.room.variants.left]\nextra = true"
            ),
            Self.rooms.replacingOccurrences(of: "base = 8, scaled = 54", with: "base = 8, scaled = 54, extra = 1"),
            Self.rooms.replacingOccurrences(of: "base = 23.8", with: "base = 23.8\nextra = true")
        ] {
            let (config, problems) = try load(rooms: rooms)
            XCTAssertNil(config.barOverride?.room)
            XCTAssertTrue(problems.contains { $0.contains("unknown key extra") })
        }
    }

    func testInvalidGeometryAndModesReportNoRoom() throws {
        for rooms in [
            Self.rooms.replacingOccurrences(of: "mode = \"add\"", with: "mode = \"max\""),
            Self.rooms.replacingOccurrences(of: "base = 8", with: "base = nan"),
            Self.rooms.replacingOccurrences(of: "base = 8", with: "base = -1000"),
            Self.rooms.replacingOccurrences(of: "mode = \"add\"", with: "mode = \"add\", clear = \"bad\""),
            Self.rooms.replacingOccurrences(of: "right = { base = 24", with: "right = { clear = \"none\", base = 24"),
            Self.rooms.replacingOccurrences(of: "dock = \"bottom\"", with: "dock = \"middle\"")
        ] {
            let (config, problems) = try load(rooms: rooms)
            XCTAssertNil(config.barOverride?.room)
            XCTAssertFalse(problems.isEmpty)
        }
    }

    func testInvalidSizeOrDockDeclarationReportNoRoom() throws {
        for size in ["'large'", "nan", "inf", "-1"] {
            let (config, problems) = try load(settings: "layout='island'\nbarSize=\(size)")
            XCTAssertNil(config.barOverride?.room)
            XCTAssertFalse(problems.isEmpty)
        }
        for rooms in [
            Self.rooms.replacingOccurrences(of: "when = [\"pins\", \"addons\"]", with: "when = []"),
            Self.rooms.replacingOccurrences(of: "when = [\"pins\", \"addons\"]", with: "when = [4]"),
            Self.rooms.replacingOccurrences(of: "unless = \"dockOverlap\"", with: "unless = false")
        ] {
            let (config, problems) = try load(rooms: rooms)
            XCTAssertNil(config.barOverride?.room)
            XCTAssertFalse(problems.isEmpty)
        }
    }

    private func load(
        settings: String = "layout='island'", rooms: String = ShellRoomProfileTests.rooms, displays: String = "all"
    ) throws -> (ShellConfig, [String]) {
        let source = """
        theme = "native"
        [island]
        root = "root"
        displays = "\(displays)"
        [widgets.root]
        \(settings)
        \(rooms)
        """
        try Data(source.utf8).write(to: root.appendingPathComponent("default/shell.toml"))
        try Data().write(to: root.appendingPathComponent("shell.toml"))
        var problems: [String] = []
        return try (XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems)), problems)
    }

    private func monitor(id: UInt32, main: Bool, notch: Bool) -> Monitor {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        return Monitor(
            id: .init(displayId: id), displayId: id, frame: frame, visibleFrame: frame,
            hasNotch: notch, name: "Display \(id)", isMain: main
        )
    }
}
