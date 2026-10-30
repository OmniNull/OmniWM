// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import TOML
import XCTest

@MainActor
final class ShellVitreusBarTests: XCTestCase {
    static let stubs: [(String, [String])] = [
        ("drawers", ["calendar", "controls", "player"]),
        ("panes", ["content", "render", "shapes"])
    ]

    func shell() throws -> URL {
        let shell = try VitreusFixture.shell()
        let folder = shell.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return shell
    }

    func probe(_ main: String) throws -> [String] {
        let widget = try VitreusFixture.probe(shell(), main)
        widget.render(ShellBarData())
        return widget.strings()
    }

    func island(
        _ shell: URL, settings: [String: ShellComponentValue] = [:], bar: ShellBarData? = nil,
        monitor: Monitor = VitreusFixture.monitor(), scale: CGFloat = 2
    ) throws -> ShellRenderedWidget {
        let widget = try ShellRenderedWidget(
            source: VitreusFixture.source(shell), scale: scale, resources: VitreusFixture.resources(shell)
        )
        VitreusFixture.settings(widget, settings)
        VitreusFixture.show(widget, on: monitor, bar: bar)
        return widget
    }

    static func numbers(_ line: String) -> [Double] {
        line.split(separator: " ").compactMap { Double($0) }
    }

    static func assertRect(_ rect: CGRect, _ target: CGRect, _ label: String = "") {
        for (value, expected) in [
            (rect.minX, target.minX), (rect.minY, target.minY), (rect.width, target.width), (rect.height, target.height)
        ] {
            XCTAssertEqual(value, expected, accuracy: 0.001, label)
        }
    }

    static func has(_ widget: ShellRenderedWidget, _ name: String) -> Bool {
        let layout = widget.surface.layout
        return layout.core.elements { _ in true }.contains { layout.core.key(of: $0) == VitreusFixture.key(name) }
    }

    func testTheProfileLeavesAnEmptyTransparentNativeStripThatReservesNothing() throws {
        let config = try VitreusFixture.config(shell())
        XCTAssertEqual(config.leading + config.center + config.trailing, [])
        let bar = try XCTUnwrap(config.barOverride)
        XCTAssertEqual(bar.settings.position, .overlappingMenuBar)
        XCTAssertEqual(bar.settings.fullWidth, true)
        XCTAssertEqual(bar.settings.reserveLayoutSpace, false)
        XCTAssertEqual(bar.settings.hideEmptyWorkspaces, false)
        XCTAssertEqual(bar.settings.transparentBackground, true)
        XCTAssertEqual(bar.settings.backgroundOpacity, 0)
        XCTAssertEqual(bar.settings.height, 1)
        XCTAssertEqual(config.island?.root, "vitreus")
        XCTAssertEqual(config.island?.sizing, .display)
    }

    func testTheRoomFollowsTheLayoutSizeAndDockRootSettings() throws {
        let shell = try shell()
        let selected = try String(contentsOf: shell.appendingPathComponent("shell.toml"), encoding: .utf8)
        func room(_ settings: String) throws -> WorkspaceBarRoom {
            try Data((selected + "\n[profiles.vitreus.widgets.vitreus]\n" + settings).utf8)
                .write(to: shell.appendingPathComponent("shell.toml"))
            return try XCTUnwrap(VitreusFixture.config(shell).barOverride?.room, settings)
        }
        typealias Edges = [WorkspaceBarRoom.Edge: WorkspaceBarRoom.Reservation]
        func total(_ strip: WorkspaceBarRoom.Edge, _ value: CGFloat) -> Edges {
            var edges: Edges = [:]
            for edge in WorkspaceBarRoom.Edge.allCases {
                edges[edge] = .init(value: edge == strip ? value : 24, mode: .total)
            }
            return edges
        }
        let island = try room("")
        XCTAssertEqual(island.edges, [.top: .init(value: 62, mode: .add, clear: .notch)])
        XCTAssertNil(island.dock)
        XCTAssertEqual(island.displays, .all)
        XCTAssertEqual(try room("size = 0.7\n").edges, [.top: .init(value: 46, mode: .add, clear: .notch)])
        var seg = total(.top, 59)
        seg[.top] = .init(value: 59, mode: .total, clear: .notch)
        let frames: [(String, Edges)] = [
            ("left", total(.left, 76)), ("right", total(.right, 76)), ("ftop", total(.top, 76)),
            ("fbottom", total(.bottom, 76)), ("seg", seg), (
                "island",
                [.top: .init(value: 62, mode: .add, clear: .notch)]
            )
        ]
        let docks: [String: WorkspaceBarRoom.Edge] = [
            "left": .right, "right": .left, "ftop": .bottom, "fbottom": .top, "seg": .bottom, "island": .bottom
        ]
        for (layout, edges) in frames {
            let pinned = try room("layout = \"\(layout)\"\npins = [\"com.apple.Safari\"]\n")
            XCTAssertEqual(pinned.edges, edges, layout)
            XCTAssertEqual(pinned.dock, try .init(edge: XCTUnwrap(docks[layout]), value: 70), layout)
        }
        XCTAssertEqual(try room("layout = \"left\"\nsize = 0.7\n").edges, total(.left, 57))
        XCTAssertEqual(try room("addons = [\"clock\"]\nsize = 0.7\n").dock, .init(edge: .bottom, value: 56))
        XCTAssertNil(try room("pins = [\"com.apple.Safari\"]\ndockOverlap = true\n").dock)
    }

    func testRootSettingsDeclareTheVitreusDefaultsAndAcceptTheProfileValues() throws {
        let shell = try shell()
        let config = try VitreusFixture.config(shell)
        let settings = try XCTUnwrap(ShellRootSettings.load("vitreus", directories: config.directories))
        let values = try settings.values(applying: [:])
        let expected: [String: ShellComponentValue] = [
            "layout": .string("island"), "size": .number(1),
            "pieces": .strings(["apple", "app", "workspaces", "title", "tray", "search", "gear", "controls", "clock"]),
            "pins": .strings([]), "addons": .strings([]), "dockOverlap": .bool(false), "visualiser": .bool(false),
            "cols": .number(24), "sens": .number(1), "hgt": .number(150), "bl": .number(1), "lay": .string("bottom"),
            "mon": .string("")
        ]
        XCTAssertEqual(values, expected)
        XCTAssertEqual(settings.options["layout"]?.choices, ["island", "left", "right", "ftop", "fbottom", "seg"])
        XCTAssertEqual(settings.options["lay"]?.choices, ["bottom", "corners", "top", "left", "right"])
        XCTAssertEqual(settings.options["dockOverlap"]?.title, "Corner docks overlap windows")
        let size = try XCTUnwrap(settings.options["size"])
        for (value, accepted) in [(0.7, true), (0.85, true), (1, true), (0.855, false), (0.69, false), (1.01, false)] {
            XCTAssertEqual(size.accepts(.number(value)), accepted, "\(value)")
        }
        let cols = try XCTUnwrap(settings.options["cols"])
        XCTAssertEqual([cols.minimum, cols.maximum, cols.step], [6, 47, 1])
        let ranges: [(String, [Double?])] = [("sens", [0.3, 3, 0.01]), ("hgt", [40, 300, 1]), ("bl", [0, 1, 0.01])]
        for (key, range) in ranges {
            let option = try XCTUnwrap(settings.options[key], key)
            XCTAssertEqual([option.minimum, option.maximum, option.step], range, key)
        }
        let profile = try TOMLDecoder().decode(
            [String: TOMLNode].self, from: Data(contentsOf: shell.appendingPathComponent("vitreus/shell.toml"))
        )
        guard case let .table(widgets)? = profile["widgets"], case let .table(root)? = widgets["vitreus"] else {
            return XCTFail("the profile needs [widgets.vitreus]")
        }
        let configured = try root.mapValues { try XCTUnwrap(ShellComponentValue($0)) }
        XCTAssertEqual(Set(configured.keys), ["layout", "size", "pins", "addons", "dockOverlap"])
        XCTAssertEqual(try settings.values(applying: configured), expected)
    }

    func testBarUnitsScaleFromSeventyPercentInHundredthsAndTheGearAlwaysStays() throws {
        let lines = try probe("""
        local units = require("../lib/vitreus/units")
        local bar = require("../lib/vitreus/bar")
        function render(ctx)
            local island = { size = { w = 1920, h = 1080 } }
            local rows = {}
            for _, size in { 1, 0.7, 0.85, 0.854, 0.856, 0.5, 2, "big" } do
                local k = units.of(island, size)
                rows[#rows + 1] = table.concat({ k.bz, k.bu, k.bcu, k.u, k.cu }, " ")
            end
            return ui.column{
                ui.text{ text = table.concat(rows, ";") },
                ui.text{ text = table.concat(bar.order({ "workspaces", "clock" }), ",") },
                ui.text{ text = table.concat(bar.order({ "gear", "bogus", 4, "title", "gear" }), ",") },
                ui.text{ text = table.concat(bar.order({}), ",") },
                ui.text{ text = table.concat(bar.order(nil), ",") },
            }
        end
        """)
        let rows = try XCTUnwrap(lines.first).split(separator: ";").map { Self.numbers(String($0)) }
        for (row, bz) in zip(rows, [1, 0.7, 0.85, 0.85, 0.86, 0.7, 1, 1]) {
            for (value, target) in zip(row, [bz, 1.35 * bz, 1.5525 * bz, 1.35, 1.5525]) {
                XCTAssertEqual(value, target, accuracy: 1e-9, "\(row)")
            }
        }
        XCTAssertEqual(rows[1][1], 0.945, accuracy: 1e-9)
        XCTAssertEqual(Array(lines.dropFirst()), [
            "workspaces,clock,gear", "gear,title", "gear", "apple,app,workspaces,title,tray,search,gear,controls,clock"
        ])
    }

    func testThePillTakesTheVitreusGeometryAndTheTitleStretchFillsTheRow() throws {
        let lines = try probe("""
        local units = require("../lib/vitreus/units")
        local bar = require("../lib/vitreus/bar")
        local function row(size, tray)
            local k = units.of({ size = { w = 1920, h = 1080 } }, size)
            local widths = {
                apple = { w = 0, grow = 0 }, app = { w = 0, grow = 0 },
                workspaces = { w = 128 * k.bu, grow = 0 }, title = { w = 0, grow = 0 },
                tray = { w = tray * k.bu, grow = if tray > 0 then (tray + 12) * k.bu else 0 },
                search = { w = 12 * k.bu, grow = 0 }, gear = { w = 15 * k.bu, grow = 0 },
                controls = { w = 13 * k.bu, grow = 0 }, clock = { w = 80, grow = 0 },
            }
            local p = bar.place(k, 960, units.edge, bar.defaults, widths)
            local values = { p.x, p.y, p.w, p.h, p.radius, p.cy }
            for _, name in { "workspaces", "title", "tray", "search", "gear", "controls", "clock" } do
                values[#values + 1] = p.slots[name].x
                values[#values + 1] = p.slots[name].w
            end
            return table.concat(values, " ")
        end
        function render(ctx)
            return ui.column{ ui.text{ text = row(1, 0) }, ui.text{ text = row(1, 42) }, ui.text{ text = row(0.7, 0) } }
        end
        """)
        let rows = lines.map(Self.numbers)
        let rest: [Double] = [
            656.25, 8, 607.5, 54, 18.9, 35,
            677.85, 172.8, 866.85, 176.5, 1043.35, 0, 1059.55, 16.2, 1091.95, 20.25, 1128.4, 17.55, 1162.15, 80
        ]
        XCTAssertEqual(rows[0].count, rest.count)
        for (value, target) in zip(rows[0], rest) {
            XCTAssertEqual(value, target, accuracy: 1e-6)
        }
        XCTAssertEqual(rows[0][8] + rows[0][9] + 16.2, rows[0][12], accuracy: 1e-6)
        XCTAssertEqual(rows[1][2], 450 * 1.35 + 54 * 1.35, accuracy: 1e-6)
        XCTAssertEqual(rows[1][10], 1043.35 + 72.9 / 2 - 56.7, accuracy: 1e-6)
        XCTAssertEqual(rows[1][11], 56.7, accuracy: 1e-6)
        for (value, target) in zip(rows[2].prefix(6), [747.375, 8, 425.25, 37.8, 13.23, 26.9]) {
            XCTAssertEqual(value, target, accuracy: 1e-6)
        }
    }
}

@MainActor
extension ShellVitreusBarTests {
    func testTheIslandDrawsOnePillInTheBarBodyAndPassesClicksBelowIt() throws {
        let shell = try shell()
        let widget = try island(shell)
        Self.assertRect(
            try VitreusFixture.frame(widget, key: "shell"),
            CGRect(x: 656.25, y: 8, width: 607.5, height: 54)
        )
        let layout = widget.surface.layout
        let shape = try VitreusFixture.element(widget, key: "shell")
        let glass = try VitreusFixture.element(widget, key: "bar")
        XCTAssertEqual(layout.core.kind(of: shape), .shape)
        XCTAssertEqual(layout.core.parent(of: shape), glass)
        let shapes = layout.core.elements { _ in true }.filter { layout.core.kind(of: $0) == .shape }
        XCTAssertEqual(shapes.count { layout.core.parent(of: $0) == glass }, 1)
        guard case let .spring(response, bounce)? = widget.surface.animation(for: shape)?.motion else {
            return XCTFail("the pill needs the calm spring")
        }
        XCTAssertEqual(response, 0.513, accuracy: 1e-6)
        XCTAssertEqual(bounce, 0.06, accuracy: 1e-6)
        let paint = layout.core.paint(of: glass)
        for (color, role, alpha) in [(paint.fill, ShellRole.secondaryContainer, 0.36), (paint.shadow, .shadow, 0.08)] {
            XCTAssertEqual(color.role & 0xFF, UInt16(role.rawValue + 1), "\(role)")
            XCTAssertEqual(Double(color.role >> 8) / 255, alpha, accuracy: 0.003, "\(role)")
        }
        XCTAssertEqual(paint.shadowRadius, 6)
        let recipe = try XCTUnwrap(ShellGlassRecipe(widget.text.string(layout.core.content(of: glass).text)))
        XCTAssertEqual(recipe.blend, 26 * 1.35, accuracy: 1e-6)
        XCTAssertEqual(recipe.rim, 0.1, accuracy: 1e-6)
        XCTAssertEqual(recipe.shadowOffset, CGPoint(x: 0, y: 1))
        XCTAssertEqual(recipe.light, CGPoint(x: -1, y: 0))
        XCTAssertFalse(recipe.flat)
        XCTAssertTrue(Self.has(widget, "bar-content"))
        let regions = widget.surface.islandRegions()
        XCTAssertTrue(regions.contains { $0.contains(CGPoint(x: 960, y: 35)) })
        XCTAssertTrue(widget.surface.containsShape(at: CGPoint(x: 960, y: 35)))
        for point in [CGPoint(x: 960, y: 75), CGPoint(x: 640, y: 35), CGPoint(x: 960, y: 540), CGPoint(x: 20, y: 4)] {
            XCTAssertFalse(regions.contains { $0.contains(point) }, "\(point)")
            XCTAssertFalse(widget.surface.containsShape(at: point), "\(point)")
        }
        XCTAssertEqual(
            widget.surface.command(at: CGPoint(x: 960, y: 35)),
            "shell trigger vitreus drawer-player \(VitreusFixture.bar().monitorId)"
        )
    }

    func testNoEnabledBarDrawsNoPillAndOtherLayoutsLeaveTheIslandToTheirOwnModules() throws {
        let shell = try shell()
        let bare = try island(shell, bar: VitreusFixture.bar(enabled: false))
        XCTAssertFalse(Self.has(bare, "shell"))
        XCTAssertFalse(Self.has(bare, "bar"))
        XCTAssertTrue(Self.has(bare, "desk-opener"))
        XCTAssertFalse(bare.surface.islandRegions().contains { $0.contains(CGPoint(x: 960, y: 35)) })
        for layout in ["left", "right", "ftop", "fbottom", "seg"] {
            let widget = try island(shell, settings: ["layout": .string(layout)])
            XCTAssertFalse(Self.has(widget, "shell"), layout)
            XCTAssertFalse(Self.has(widget, "desk-opener"), layout)
        }
        let small = try island(shell, settings: ["size": .number(0.7), "pieces": .strings(["clock"])])
        Self.assertRect(
            try VitreusFixture.frame(small, key: "shell"), CGRect(x: 747.375, y: 8, width: 425.25, height: 37.8)
        )
    }

    func testTheOpenerSitsInTheIslandAtTheVitreusSpotAndKeepsItsDisplayTrigger() throws {
        let shell = try shell()
        for monitor in [VitreusFixture.monitor(), VitreusFixture.monitor(width: 1440, height: 900)] {
            let widget = try island(shell, settings: ["size": .number(0.7)], monitor: monitor)
            let opener = try VitreusFixture.frame(widget, key: "desk-opener")
            let size = 32 * 1.5525
            XCTAssertEqual(opener.midX, monitor.frame.width - 41 * 1.5525, accuracy: 0.001)
            XCTAssertEqual(opener.midY, 35, accuracy: 0.001)
            XCTAssertEqual(opener.width, size, accuracy: 0.001)
            XCTAssertEqual(opener.height, size, accuracy: 0.001)
            let center = CGPoint(x: opener.midX, y: opener.midY)
            let display = VitreusFixture.bar(monitor).monitorId
            XCTAssertEqual(widget.surface.command(at: center), "shell trigger vitreus desk-open \(display)")
            VitreusFixture.trigger(widget.instance, "desk-open", display)
            VitreusFixture.show(widget, on: monitor)
            XCTAssertTrue(Self.has(widget, "desk"))
            XCTAssertEqual(widget.surface.command(at: center), "shell trigger vitreus desk-close \(display)")
        }
    }

    func testFullWidthStretchesThePillFromTheEdgeToTheDeskOpener() throws {
        let shell = try shell()
        for monitor in [VitreusFixture.monitor(), VitreusFixture.monitor(width: 1440, height: 900)] {
            var data = VitreusFixture.bar(monitor)
            data.style.fullWidth = true
            let widget = try island(shell, bar: data, monitor: monitor)
            let pill = try VitreusFixture.frame(widget, key: "shell")
            let opener = try VitreusFixture.frame(widget, key: "desk-opener")
            XCTAssertEqual(pill.minX, 8, accuracy: 0.001)
            XCTAssertEqual(pill.minY, 8, accuracy: 0.001)
            XCTAssertEqual(pill.height, 54, accuracy: 0.001)
            XCTAssertEqual(opener.minX - pill.maxX, 12 * 1.35, accuracy: 0.001)
            XCTAssertTrue(widget.surface.containsShape(at: CGPoint(x: pill.maxX - 30, y: pill.midY)))
        }
    }

    func testTogglingFullWidthWithADrawerOpenKeepsTheDrawerUnderThePillCentre() throws {
        let shell = try shell()
        let monitor = VitreusFixture.monitor()
        var data = VitreusFixture.bar(monitor)
        let widget = try island(shell, bar: data, monitor: monitor)
        VitreusFixture.trigger(widget.instance, "drawer-calendar", data.monitorId)
        for fullWidth in [true, false, true] {
            data.style.fullWidth = fullWidth
            VitreusFixture.show(widget, on: monitor, bar: data)
            let pill = try VitreusFixture.frame(widget, key: "shell")
            let drawer = try VitreusFixture.frame(widget, key: "drawer")
            let width = fullWidth ? monitor.frame.width - 57 * 1.5525 - 12 * 1.35 - 8 : 607.5
            XCTAssertEqual(pill.width, width, accuracy: 0.001, "full width \(fullWidth)")
            XCTAssertEqual(drawer.midX, pill.midX, accuracy: 0.001, "full width \(fullWidth)")
        }
    }

    func testTheDeskBesideTheBarMatchesTheDeskWithoutIt() throws {
        let shell = try shell()
        func opened(_ enabled: Bool) throws -> ShellRenderedWidget {
            let data = VitreusFixture.bar(enabled: enabled)
            let widget = try island(shell, bar: data)
            VitreusFixture.trigger(widget.instance, "desk-open", data.monitorId)
            VitreusFixture.show(widget, bar: data)
            return widget
        }
        let beside = try opened(true)
        let alone = try opened(false)
        XCTAssertTrue(Self.has(beside, "shell"))
        XCTAssertFalse(Self.has(alone, "shell"))
        let keys = ["desk", "desk-glass", "desk-shape", "desk-clip", "page", "grip", "close", "tab-pad", "tab-focus"]
        for key in keys {
            Self.assertRect(try VitreusFixture.frame(beside, key: key), try VitreusFixture.frame(alone, key: key), key)
        }
        let recipes = try [beside, alone].map { widget in
            let layout = widget.surface.layout
            let glass = try VitreusFixture.element(widget, key: "desk-glass")
            return try XCTUnwrap(ShellGlassRecipe(widget.text.string(layout.core.content(of: glass).text)))
        }
        XCTAssertEqual(recipes[0], recipes[1])
        XCTAssertEqual(beside.strings().first, "glass:35.1:-1:0:0:1")
        XCTAssertEqual(Array(beside.strings().suffix(alone.strings().count)), alone.strings())
        XCTAssertNotIdentical(try VitreusFixture.body(beside), try VitreusFixture.body(beside, key: "bar"))
    }

    func testANotchedDisplayLowersThePillAndAddsTheNotchToTheTopRoom() throws {
        let shell = try shell()
        let notched = ShellVitreusNotchesTests.notched()
        let plain = VitreusFixture.monitor()
        let lowered = try island(shell, monitor: notched)
        let level = try island(shell, monitor: plain)
        Self.assertRect(
            try VitreusFixture.frame(lowered, key: "shell"), CGRect(x: 656.25, y: 40, width: 607.5, height: 54)
        )
        Self.assertRect(
            try VitreusFixture.frame(level, key: "shell"),
            CGRect(x: 656.25, y: 8, width: 607.5, height: 54)
        )
        Self.assertRect(
            try VitreusFixture.frame(lowered, key: "desk-opener"), try VitreusFixture.frame(level, key: "desk-opener")
        )
        VitreusFixture.trigger(lowered.instance, "drawer-calendar", VitreusFixture.bar(notched).monitorId)
        VitreusFixture.show(lowered, on: notched)
        XCTAssertEqual(try VitreusFixture.frame(lowered, key: "drawer-content-calendar").minY, 94, accuracy: 0.001)
        let selected = try String(contentsOf: shell.appendingPathComponent("shell.toml"), encoding: .utf8)
        let rooms: [(String, CGFloat)] = [("island", 62), ("seg", 59)]
        for (layout, room) in rooms {
            try Data((selected + "\n[profiles.vitreus.widgets.vitreus]\nlayout = \"\(layout)\"\n").utf8)
                .write(to: shell.appendingPathComponent("shell.toml"))
            let controller = roomController()
            controller.settings.workspaceBar.profileOverride = try XCTUnwrap(VitreusFixture.config(shell).barOverride)
            let piece = layout == "seg" ? "notch-middle" : "shell"
            for monitor in [notched, plain] {
                let label = "\(layout), notch \(monitor.hasNotch)"
                let menu = monitor.frame.maxY - monitor.visibleFrame.maxY
                let top = controller.workspaceBarReservedInsets(for: monitor).top + menu
                XCTAssertEqual(top, room + (monitor.hasNotch ? 32 : 0), label)
                let widget = try island(shell, settings: ["layout": .string(layout)], monitor: monitor)
                let bottom = try VitreusFixture.frame(widget, key: piece).maxY
                XCTAssertEqual(top - bottom, layout == "seg" ? 10.4 : 0, accuracy: 0.001, label)
            }
        }
    }

    func testTheDefaultVariantOverlapsTheAutoHiddenMenuBarAndShowsTheFocusedAppMenu() throws {
        let shell = try shell()
        let monitor = VitreusFixture.monitor()
        let profile = try XCTUnwrap(VitreusFixture.config(shell).barOverride)
        XCTAssertEqual(profile.settings.position, .overlappingMenuBar)
        let resolved = WorkspaceBarSettings().isolated(profileOverride: profile).resolved(for: monitor)
        XCTAssertTrue(WorkspaceBarManager.hidesMenuBar(resolved))
        XCTAssertNotEqual(profile.room?.edges[.top]?.clear, .menuBar)
        XCTAssertEqual(profile.room?.edges[.top]?.clear, .notch)
        var data = VitreusFixture.bar(monitor)
        data.style.hidesMenuBar = true
        let widget = try island(shell, bar: data, monitor: monitor)
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "shell").minY, 8, accuracy: 0.001)
        XCTAssertFalse(Self.has(widget, "bar-app"))
        widget.set("menuApp") { ShellMenuApp(pid: 1, name: "Safari", bundle: "com.apple.Safari").write(into: &$0) }
        VitreusFixture.show(widget, on: monitor, bar: data)
        let deps = widget.output().withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self).deps }
        XCTAssertNotEqual(deps & ShellDataKey.menuApp.bit, 0)
        let zone = try VitreusFixture.frame(widget, key: "bar-app")
        XCTAssertEqual(widget.surface.command(at: CGPoint(x: zone.midX, y: zone.midY)), "menu app")
        let layout = widget.surface.layout
        let icon = try VitreusFixture.element(widget, key: "bar-app-icon")
        let image = try XCTUnwrap(layout.core.elements { _ in true }.first { layout.core.parent(of: $0) == icon })
        XCTAssertEqual(layout.core.kind(of: image), .image)
        XCTAssertEqual(layout.core.content(of: image).iconSource, .bundle)
        XCTAssertEqual(widget.text.string(layout.core.content(of: image).text), "com.apple.Safari")
    }

    func roomController() -> WMController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitreus-room-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        settings.island.enabled = true
        settings.workspaceBar.enabled = true
        settings.workspaceBar.revealModifier = .off
        settings.workspaceBar.autoHide = false
        return WMController(settings: settings)
    }
}
