// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

private struct NotchRun {
    let size: Double
    let fullWidth: Bool
    let media: Bool

    var label: String {
        "size \(size), full width \(fullWidth), media \(media)"
    }

    static let all = [1, 0.7].flatMap { size in
        [false, true].flatMap { fullWidth in
            [false, true].map { NotchRun(size: size, fullWidth: fullWidth, media: $0) }
        }
    }
}

private struct PlacedRow {
    let x: Double
    let width: Double
    let titleX: Double
    let titleWidth: Double
    let lead: Double
    let trail: Double
    let x0: Double
    let x1: Double
    let least: Double

    init(_ values: [Double]) {
        x = values[0]
        width = values[1]
        titleX = values[2]
        titleWidth = values[3]
        lead = values[4]
        trail = values[5]
        x0 = values[6]
        x1 = values[7]
        least = values[8]
    }

    var titleEnd: Double {
        titleX + titleWidth
    }
}

private let accuracy = 1e-6
private let inked: Set<ElementKind> = [.label, .symbol, .image, .bitmap, .path, .shape, .progress, .shader, .slider]
private let defaultWorkspaces = 3
private let splitTray = 18
private let cappedTray = 60

@MainActor
extension ShellVitreusBarTests {
    static func fourteenInch(notched: Bool = true) -> Monitor {
        Monitor(
            id: .init(displayId: 95400), displayId: 95400, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944), hasNotch: notched, notchRange: 662 ... 850,
            notchHeight: 32, name: VitreusFixture.primary
        )
    }

    static func notch(of monitor: Monitor) throws -> CGRect {
        try XCTUnwrap(ShellIslandGeometry(monitor: monitor, size: monitor.frame.size).notch)
    }

    private func notchWidget(
        _ shell: URL, _ run: NotchRun, on monitor: Monitor, tray: [ShellHiddenBarItem] = [], pieces: [String]? = nil,
        workspaces: Int = defaultWorkspaces
    ) throws -> ShellRenderedWidget {
        let widget = try ShellRenderedWidget(
            source: VitreusFixture.source(shell), scale: 2, resources: VitreusFixture.resources(shell)
        )
        if !tray.isEmpty {
            widget.set("hiddenBar") { ShellHiddenBarData(enabled: true, available: true, items: tray).write(into: &$0) }
        }
        var settings: [String: ShellComponentValue] = ["size": .number(run.size)]
        if let pieces { settings["pieces"] = .strings(pieces) }
        VitreusFixture.settings(widget, settings)
        widget.set("clock") { $0.string("6:42 pm") }
        widget.set("date") { $0.string("Tue 28") }
        widget.set("app") { $0.string("Safari") }
        widget.set("title") { $0.string("A long document title that runs well past the room beside the notch") }
        widget.set("menuApp") { ShellMenuApp(pid: 1, name: "Safari", bundle: "com.apple.Safari").write(into: &$0) }
        widget.set("privacy") { ShellPrivacy(microphone: true, camera: false).write(into: &$0) }
        if run.media {
            widget.set("media") { ShellMedia(title: "Song", app: "Music", playing: true).write(into: &$0) }
        }
        VitreusFixture.show(widget, on: monitor, bar: notchBar(monitor, run, workspaces: workspaces))
        return widget
    }

    private func notchBar(_ monitor: Monitor, _ run: NotchRun, workspaces: Int = defaultWorkspaces) -> ShellBarData {
        var bar = VitreusFixture.bar(monitor)
        bar.style.fullWidth = run.fullWidth
        bar.style.hidesMenuBar = true
        bar.workspaces = (1 ... workspaces).map { String($0) }.map { id in
            ShellBarWorkspace(id: id, name: id, focused: id == "1", windows: [ShellBarItem(
                id: id, bundle: "test.app", name: "App", focused: id == "1", count: 1, hidden: 0,
                windows: [.init(id: "window-" + id, title: "Window " + id, focused: id == "1", hidden: false)]
            )])
        }
        return bar
    }

    private func drawnContent(_ widget: ShellRenderedWidget) throws -> [(frame: CGRect, title: Bool)] {
        let layout = widget.surface.layout
        let scene = widget.surface.scene
        let root = try VitreusFixture.element(widget, key: "bar-hover")
        let title = VitreusFixture.find(widget, key: "title-region") ?? .none
        return layout.core.elements { _ in true }.filter { element in
            var ancestor = layout.core.parent(of: element)
            while ancestor != .none, ancestor != root {
                ancestor = layout.core.parent(of: ancestor)
            }
            let kind = layout.core.kind(of: element)
            let filled = (kind == .box || kind == .group) && layout.core.paint(of: element).fill != .clear
            return ancestor == root && !layout.core.paint(of: element).masks && (inked.contains(kind) || filled)
        }.map { element in
            var frame = CGRect(layout.core.absoluteFrame(of: element))
            if layout.core.kind(of: element) == .path {
                let stroke = ShellLayerScene.engineQueue.sync { () -> CGRect? in
                    guard let shape = scene.layers[element.slot] as? CAShapeLayer,
                          let path = shape.path else { return nil }
                    return path.boundingBoxOfPath.insetBy(dx: -shape.lineWidth / 2, dy: -shape.lineWidth / 2)
                }
                frame = stroke?.offsetBy(dx: frame.minX, dy: frame.minY) ?? frame
            }
            var ancestor = element
            while ancestor != .none, ancestor != title { ancestor = layout.core.parent(of: ancestor) }
            return (frame, title != .none && ancestor == title)
        }
    }

    private func assertMelt(_ widget: ShellRenderedWidget, notch: CGRect, _ label: String) throws {
        let layout = widget.surface.layout
        let scene = widget.surface.scene
        let melt = try VitreusFixture.element(widget, key: "notch-melt")
        let pill = try VitreusFixture.element(widget, key: "shell")
        XCTAssertEqual(layout.core.kind(of: melt), .shape, label)
        XCTAssertEqual(layout.core.parent(of: melt), try VitreusFixture.element(widget, key: "bar"), label)
        let radii = ShellLayerScene.engineQueue.sync { [melt, pill].map { scene.glassShapes[$0.slot]?.radius } }
        let radius = try XCTUnwrap(radii[0], label)
        XCTAssertEqual(radius, try XCTUnwrap(radii[1], label), accuracy: 0.001, label)
        let frame = CGRect(layout.core.absoluteFrame(of: melt))
        XCTAssertEqual(frame.minX, notch.minX, accuracy: 0.001, label)
        XCTAssertEqual(frame.width, notch.width, accuracy: 0.001, label)
        XCTAssertEqual(frame.maxY, notch.maxY, accuracy: 0.001, label)
        XCTAssertEqual(frame.minY, notch.minY - radius, accuracy: 0.001, label)
    }

    func testTheIslandBarMeltsIntoTheNotchAndKeepsEveryPieceOutsideIt() throws {
        let shell = try shell()
        let notched = Self.fourteenInch()
        let plain = Self.fourteenInch(notched: false)
        let notch = try Self.notch(of: notched)
        for run in NotchRun.all {
            let widget = try notchWidget(shell, run, on: notched)
            let level = try notchWidget(shell, run, on: plain)
            let pill = try VitreusFixture.frame(widget, key: "shell")
            let flat = try VitreusFixture.frame(level, key: "shell")
            XCTAssertEqual(pill.minY, flat.minY, accuracy: 0.001, run.label)
            XCTAssertEqual(pill.height, flat.height, accuracy: 0.001, run.label)
            let content = try drawnContent(widget)
            XCTAssertFalse(content.isEmpty, run.label)
            for drawn in content {
                let rect = drawn.frame
                XCTAssertTrue(
                    rect.maxX <= notch.minX || rect.minX >= notch.maxX || (drawn.title && rect.minY >= notch.maxY),
                    "\(run.label) \(rect)"
                )
                XCTAssertTrue(rect.minX >= pill.minX && rect.maxX <= pill.maxX, "\(run.label) \(rect)")
            }
            try assertMelt(widget, notch: notch, run.label)
            XCTAssertFalse(Self.has(level, "notch-melt"), run.label)
            if run.fullWidth {
                Self.assertRect(pill, flat, run.label)
            } else {
                XCTAssertEqual(pill.midX, notch.midX, accuracy: 0.001, run.label)
                let title = try VitreusFixture.frame(widget, key: "title-button")
                if title.minY >= notch.maxY {
                    XCTAssertLessThanOrEqual(title.width, notch.width, run.label)
                } else {
                    XCTAssertEqual(
                        title.width, try VitreusFixture.frame(level, key: "title-button").width,
                        accuracy: 0.001, run.label
                    )
                }
            }
            let opener = try VitreusFixture.frame(widget, key: "desk-opener")
            if run.fullWidth {
                Self.assertRect(opener, try VitreusFixture.frame(level, key: "desk-opener"), run.label)
            } else {
                XCTAssertGreaterThanOrEqual(
                    opener.minX,
                    try VitreusFixture.frame(widget, key: "bar-clock").maxX,
                    run.label
                )
                XCTAssertLessThanOrEqual(opener.maxX, pill.maxX, run.label)
                XCTAssertEqual(opener.midY, pill.midY, accuracy: 0.001, run.label)
            }
        }
    }

    private static func pieceGroups(workspaces: Int) -> [[String]] {
        [
            ["bar-apple"], ["bar-app"], (1 ... workspaces).map { "workspace-mark-\($0)" },
            ["title-app", "title-text", "title-previous", "title-play", "title-next"],
            ["bar-search"], ["bar-omniwm"], ["bar-controls"], ["bar-clock"], ["desk-opener"]
        ]
    }

    private func frames(_ widget: ShellRenderedWidget, _ keys: [String]) throws -> [CGRect] {
        try keys.filter { Self.has(widget, $0) }.map { try VitreusFixture.frame(widget, key: $0) }
    }

    private func assertPiecesApart(
        _ widget: ShellRenderedWidget, tray: [CGRect], workspaces: Int = defaultWorkspaces, _ label: String
    ) throws {
        let groups = try Self.pieceGroups(workspaces: workspaces).map { try frames(widget, $0) }
        for (index, group) in groups.enumerated() {
            for rect in group {
                for other in groups.dropFirst(index + 1).joined() + tray {
                    XCTAssertFalse(rect.insetBy(dx: 0.5, dy: 0.5).intersects(other), "\(label) \(rect) \(other)")
                }
            }
        }
    }

    private func assertOnScreenBesideTheNotch(
        _ widget: ShellRenderedWidget,
        on monitor: Monitor,
        _ label: String
    ) throws {
        let notch = try Self.notch(of: monitor)
        let pill = try VitreusFixture.frame(widget, key: "shell")
        for rect in [pill, try VitreusFixture.frame(widget, key: "desk-opener")] {
            XCTAssertGreaterThanOrEqual(rect.minX, monitor.frame.minX, "\(label) \(rect)")
            XCTAssertLessThanOrEqual(rect.maxX, monitor.frame.maxX, "\(label) \(rect)")
        }
        for drawn in try drawnContent(widget) {
            let rect = drawn.frame
            XCTAssertTrue(
                rect.maxX <= notch.minX || rect.minX >= notch.maxX || (drawn.title && rect.minY >= notch.maxY),
                "\(label) \(rect)"
            )
            XCTAssertTrue(rect.minX >= pill.minX && rect.maxX <= pill.maxX, "\(label) \(rect)")
        }
    }

    func testAFullTrayStaysOnScreenAndOutOfTheNotchInBothWidths() throws {
        let shell = try shell()
        let notched = Self.fourteenInch()
        let reordered = ["apple", "app", "workspaces", "title", "search", "omniwm", "tray", "controls", "clock"]
        let cases = [splitTray, cappedTray].flatMap { count in NotchRun.all.map { (count, $0, [String]?.none) } }
            + NotchRun.all.filter(\.media).map { (cappedTray, $0, Optional(reordered)) }
        for (trayItems, run, pieces) in cases {
            let label = "\(trayItems) tray items, \(run.label), pieces \(pieces ?? [])"
            let tray = (0 ..< trayItems).map {
                ShellHiddenBarItem(id: "item-\($0)", name: "Item \($0)", image: nil, width: 22, height: 22)
            }
            let widget = try notchWidget(shell, run, on: notched, tray: tray, pieces: pieces)
            try assertOnScreenBesideTheNotch(widget, on: notched, label)
            let shown = try frames(widget, tray.map { "tray-" + $0.id })
            try assertPiecesApart(widget, tray: shown, label)
            XCTAssertGreaterThan(try VitreusFixture.frame(widget, key: "title-text").width, 0, label)
            if !run.media {
                if Self.has(widget, "title-app") {
                    XCTAssertGreaterThan(try VitreusFixture.frame(widget, key: "title-app").width, 0, label)
                } else {
                    XCTAssertTrue(VitreusFixture.labels(widget).contains { $0.text.hasPrefix("Safari · ") }, label)
                    XCTAssertGreaterThanOrEqual(
                        try VitreusFixture.frame(widget, key: "title-text").minY,
                        try Self.notch(of: notched).maxY, label
                    )
                }
            }
            if trayItems == splitTray {
                XCTAssertEqual(shown.count, trayItems, label)
            } else {
                XCTAssertFalse(shown.isEmpty, label)
                XCTAssertLessThan(shown.count, trayItems, label)
            }
        }
    }

    func testTrayBeforeTitleStaysBesideTheNotch() throws {
        let shell = try shell()
        let monitor = Self.fourteenInch()
        let orders = [
            ["apple", "app", "workspaces", "tray", "title", "search", "omniwm", "controls", "clock"],
            ["tray", "apple", "app", "workspaces", "title", "search", "omniwm", "controls", "clock"],
            ["apple", "app", "workspaces", "tray", "search", "omniwm", "controls", "clock", "title"],
            ["apple", "app", "workspaces", "tray", "search", "omniwm", "controls", "clock"]
        ]
        let cases = [splitTray, cappedTray].flatMap { count in
            orders.flatMap { pieces in NotchRun.all.map { (count, pieces, $0) } }
        }
        for (trayItems, pieces, run) in cases {
            let label = "\(trayItems) tray items, \(run.label), pieces \(pieces)"
            let tray = (0 ..< trayItems).map {
                ShellHiddenBarItem(id: "prefix-\($0)", name: "Item \($0)", image: nil, width: 22, height: 22)
            }
            let widget = try notchWidget(shell, run, on: monitor, tray: tray, pieces: pieces)
            try assertOnScreenBesideTheNotch(widget, on: monitor, label)
            let shown = try frames(widget, tray.map { "tray-" + $0.id })
            if trayItems == splitTray {
                XCTAssertEqual(shown.count, tray.count, label)
            } else {
                XCTAssertFalse(shown.isEmpty, label)
                XCTAssertLessThan(shown.count, tray.count, label)
            }
            try assertPiecesApart(widget, tray: shown, label)
            XCTAssertTrue(Self.has(widget, "workspace-pill-shape"), label)
            for id in 1 ... defaultWorkspaces {
                let frame = try VitreusFixture.frame(widget, key: "workspace-hit-\(id)")
                XCTAssertEqual(
                    widget.surface.command(at: CGPoint(x: frame.midX, y: frame.midY)), "switch-workspace \(id)", label
                )
            }
            if run.fullWidth, pieces.contains("title") {
                XCTAssertGreaterThan(try VitreusFixture.frame(widget, key: "title-text").width, 0, label)
                if run.media {
                    for key in ["title-previous", "title-play", "title-next"] {
                        XCTAssertTrue(Self.has(widget, key), "\(label) \(key)")
                    }
                }
            }
            for item in tray where Self.has(widget, "tray-" + item.id) {
                let frame = try VitreusFixture.frame(widget, key: "tray-" + item.id)
                XCTAssertEqual(
                    widget.surface.command(at: CGPoint(x: frame.midX, y: frame.midY)),
                    "hidden-bar activate " + item.id,
                    label
                )
            }
        }
    }

    func testCrowdedWorkspacePrefixStaysBesideTheNotch() throws {
        let shell = try shell()
        let monitor = Self.fourteenInch()
        let workspaces = 20
        for run in NotchRun.all {
            let widget = try notchWidget(shell, run, on: monitor, workspaces: workspaces)
            try assertOnScreenBesideTheNotch(widget, on: monitor, run.label)
            XCTAssertEqual(
                try frames(widget, (1 ... workspaces).map { "workspace-square-\($0)" }).count, workspaces, run.label
            )
            try assertPiecesApart(widget, tray: [], workspaces: workspaces, run.label)
            for id in 1 ... workspaces {
                let frame = try VitreusFixture.frame(widget, key: "workspace-hit-\(id)")
                XCTAssertEqual(
                    widget.surface.command(at: CGPoint(x: frame.midX, y: frame.midY)),
                    "switch-workspace \(id)",
                    run.label
                )
            }
        }
    }

    func testHiddenWorkspaceSlotsCancelTheirAnimationTimer() throws {
        let widget = try VitreusFixture.probe(shell(), """
        local marks = require("../lib/vitreus/bar/marks")
        function render(ctx)
            local model = { state = ctx.state, data = { settings = {}, bar = {
                style = {}, workspaces = {}, scratchpads = { { id = 7, visible = true } },
            } } }
            local slot = { hidden = ctx.data.app == "hidden",
                positions = if ctx.data.app == "partial" then { overview = 10 } else nil }
            marks.prepare(model, { k = { bu = 1, bcu = 1 }, island = { visible = true },
                pill = { slots = { workspaces = slot } } })
            return ui.text{ text = "marks" }
        end
        """)
        for (state, expected) in [("visible", 1), ("hidden", 0), ("partial", 0), ("visible", 1)] {
            widget.set("app") { $0.string(state) }
            widget.render(ShellBarData())
            XCTAssertEqual(omni_vm_service_stats(widget.vm).reserved, UInt32(expected), state)
        }
    }

    func testPlaceFillsTheRightSideFromTheBandAndDocksTheOpenerLast() throws {
        let monitor = Self.fourteenInch()
        let notch = try Self.notch(of: monitor)
        let rows = try probe("""
        local units = require("../lib/vitreus/units")
        local bar = require("../lib/vitreus/bar")
        function render(ctx)
            local items, w = {}, \(monitor.frame.width)
            local split = table.find(bar.defaults, "title")
            for _, size in { 1, 0.7 } do
                local k = units.of({ size = { w = w, h = \(monitor.frame.height) } }, size)
                local widths = {}
                for _, name in bar.defaults do widths[name] = { w = 0, grow = 0 } end
                for name, width in { workspaces = 128, search = 12, omniwm = 15, controls = 13 } do
                    widths[name] = { w = width * k.bu, grow = 0 }
                end
                widths.clock = { w = 80, grow = 0 }
                local gap = 12 * k.bu
                local band = { x0 = \(notch.minX) - gap, x1 = \(notch.maxX) + gap }
                local p = bar.place(k, w / 2, units.edge, bar.defaults, widths, nil, nil, band, 30 * k.bu)
                local row = { band.x0, band.x1, p.right, p.slots.title.x + p.slots.title.w }
                for index = split + 1, #bar.defaults do
                    local slot = p.slots[bar.defaults[index]]
                    if slot.w > 0 then
                        row[#row + 1] = slot.x
                        row[#row + 1] = slot.w
                    end
                end
                row[#row + 1] = p.slots.opener.x
                row[#row + 1] = p.slots.opener.w
                items[#items + 1] = ui.text{ text = table.concat(row, " ") }
            end
            return ui.column(items)
        end
        """).map { Self.numbers($0) }
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            let items = stride(from: 4, to: row.count - 1, by: 2).map { (x: row[$0], w: row[$0 + 1]) }
            let first = try XCTUnwrap(items.first), last = try XCTUnwrap(items.last)
            XCTAssertEqual(row[3], row[0], accuracy: accuracy)
            XCTAssertEqual(first.x, row[1], accuracy: accuracy)
            XCTAssertEqual(last.x + last.w, row[2], accuracy: accuracy)
            let gaps = zip(items, items.dropFirst()).map { $1.x - ($0.x + $0.w) }
            for gap in gaps {
                XCTAssertEqual(gap, try XCTUnwrap(gaps.first), accuracy: accuracy)
            }
        }
    }

    private func bandRows() throws -> [PlacedRow] {
        let monitor = Self.fourteenInch()
        let notch = try Self.notch(of: monitor)
        return try probe("""
        local units = require("../lib/vitreus/units")
        local bar = require("../lib/vitreus/bar")
        local title = require("../lib/vitreus/bar/title")
        local function line(p, band, least)
            local split = table.find(bar.defaults, "title")
            local lead, trail = -math.huge, math.huge
            for index, name in bar.defaults do
                local slot = p.slots[name]
                if slot.w > 0 and index < split then lead = math.max(lead, slot.x + slot.w) end
                if slot.w > 0 and index > split then trail = math.min(trail, slot.x) end
            end
            local t = p.slots.title
            return ui.text{ text = table.concat({ p.x, p.w, t.x, t.w, lead, trail, band.x0, band.x1, least }, " ") }
        end
        function render(ctx)
            local items, none, w = {}, { x0 = 0, x1 = 0 }, \(monitor.frame.width)
            for _, size in { 1, 0.7 } do
                local k = units.of({ size = { w = w, h = \(monitor.frame.height) } }, size)
                local widths, least, full = {}, title.least * k.bu, w - 2 * units.edge
                for _, name in bar.defaults do widths[name] = { w = 0, grow = 0 } end
                for name, width in { workspaces = 128, search = 12, omniwm = 15, controls = 13 } do
                    widths[name] = { w = width * k.bu, grow = 0 }
                end
                widths.clock = { w = 80, grow = 0 }
                local function at(given, band)
                    local p = bar.place(k, w / 2, units.edge, bar.defaults, widths, given, nil, band)
                    items[#items + 1] = line(p, band or none, least)
                    return p
                end
                local natural = at(nil, nil)
                local band = { x0 = \(notch.minX) - natural.gap, x1 = \(notch.maxX) + natural.gap }
                at(nil, band)
                local wide = at(full, nil)
                at(full, band)
                local x0 = wide.slots.title.x + least / 2
                at(full, { x0 = x0, x1 = x0 + band.x1 - band.x0 })
            end
            return ui.column(items)
        end
        """).map { PlacedRow(Self.numbers($0)) }
    }

    func testPlaceWidensAroundTheBandAndFullWidthMovesATightTitleRight() throws {
        let rows = try bandRows()
        XCTAssertEqual(rows.count, 10)
        for start in stride(from: 0, to: rows.count, by: 5) {
            let natural = rows[start], banded = rows[start + 1]
            XCTAssertEqual(banded.x + banded.width / 2, (banded.x0 + banded.x1) / 2, accuracy: accuracy)
            XCTAssertEqual(banded.titleWidth, natural.titleWidth, accuracy: accuracy)
            XCTAssertLessThanOrEqual(max(banded.lead, banded.titleEnd) - banded.x0, accuracy)
            XCTAssertGreaterThanOrEqual(banded.trail - banded.x1, -accuracy)
            XCTAssertEqual(min(banded.x0 - banded.titleEnd, banded.trail - banded.x1), 0, accuracy: accuracy)
            let wide = rows[start + 2], full = rows[start + 3], tight = rows[start + 4]
            XCTAssertEqual(full.x, wide.x, accuracy: accuracy)
            XCTAssertEqual(full.width, wide.width, accuracy: accuracy)
            XCTAssertEqual(full.titleX, wide.titleX, accuracy: accuracy)
            XCTAssertEqual(full.titleEnd, full.x0, accuracy: accuracy)
            XCTAssertLessThan(full.lead, full.x0)
            XCTAssertGreaterThan(full.trail, full.x1)
            XCTAssertLessThan(tight.x0 - wide.titleX, tight.least)
            XCTAssertEqual(tight.titleX, tight.x1, accuracy: accuracy)
            XCTAssertEqual(tight.titleEnd, wide.titleEnd, accuracy: accuracy)
        }
    }

    func testTheIslandRoomStartsAtTheBarBottomOnANotchedDisplay() throws {
        let shell = try shell()
        let monitor = Self.fourteenInch()
        let selected = try String(contentsOf: shell.appendingPathComponent("shell.toml"), encoding: .utf8)
        for size in [1, 0.7] {
            try Data((selected + "\n[profiles.vitreus.widgets.vitreus]\nsize = \(size)\n").utf8)
                .write(to: shell.appendingPathComponent("shell.toml"))
            let controller = roomController()
            controller.settings.workspaceBar.profileOverride = try XCTUnwrap(VitreusFixture.config(shell).barOverride)
            let menu = monitor.frame.maxY - monitor.visibleFrame.maxY
            let top = controller.workspaceBarReservedInsets(for: monitor).top + menu
            let widget = try island(shell, settings: ["size": .number(size)], monitor: monitor)
            XCTAssertEqual(top, try VitreusFixture.frame(widget, key: "shell").maxY.rounded(), "size \(size)")
        }
    }

    func testTheNotchedTitleUsesItsMeasuredLineAndKeepsItsClickRegion() throws {
        let shell = try shell()
        let config = try VitreusFixture.config(shell)
        let root = try XCTUnwrap(ShellRootSettings.load("vitreus", directories: config.directories))
        let option = try XCTUnwrap(root.options["size"])
        let minimum = try XCTUnwrap(option.minimum), maximum = try XCTUnwrap(option.maximum)
        let step = try XCTUnwrap(option.step)
        let monitor = Self.fourteenInch()
        let notch = try Self.notch(of: monitor)
        let unit = try XCTUnwrap(probe("""
        local units = require("../lib/vitreus/units")
        function render(ctx) return ui.text{ text = tostring(units.u) } end
        """).first.flatMap(Double.init))
        for fullWidth in [false, true] {
            for index in Int((minimum / step).rounded()) ... Int((maximum / step).rounded()) {
                let size = Double(index) * step
                let run = NotchRun(size: size, fullWidth: fullWidth, media: false)
                let widget = try notchWidget(shell, run, on: monitor)
                let pill = try VitreusFixture.frame(widget, key: "shell")
                let text = try VitreusFixture.frame(widget, key: "title-text")
                let button = try VitreusFixture.frame(widget, key: "title-button")
                let available = pill.maxY - notch.maxY - 2 * unit * size
                let compact = text.height <= available
                XCTAssertEqual(button.minY >= notch.maxY, compact, run.label)
                let label = try XCTUnwrap(VitreusFixture.labels(widget).first { $0.frame == text })
                if compact {
                    XCTAssertTrue(label.text.hasPrefix("Safari · "), run.label)
                    XCTAssertFalse(Self.has(widget, "title-app"), run.label)
                    XCTAssertEqual(button.midX, notch.midX, accuracy: accuracy, run.label)
                    XCTAssertTrue(button.contains(text), run.label)
                    XCTAssertLessThanOrEqual(button.maxY, pill.maxY - unit * size, run.label)
                } else {
                    XCTAssertTrue(Self.has(widget, "title-app"), run.label)
                    XCTAssertTrue(button.maxX <= notch.minX || button.minX >= notch.maxX, run.label)
                }
                XCTAssertEqual(
                    widget.surface.command(at: CGPoint(x: button.midX, y: button.midY)),
                    "shell trigger vitreus drawer-player \(VitreusFixture.bar(monitor).monitorId)", run.label
                )
            }
        }
    }

    func testTheCompactNotchTitleJoinsOnlyNonemptyPartsAndStaysOmittedWhenRemoved() throws {
        let shell = try shell()
        let monitor = Self.fourteenInch()
        let widget = try notchWidget(shell, NotchRun(size: 1, fullWidth: true, media: false), on: monitor)
        for (app, title, expected) in [("", "Document", "Document"), ("Safari", "", "Safari"), ("", "", "")] {
            widget.set("app") { $0.string(app) }
            widget.set("title") { $0.string(title) }
            VitreusFixture.show(widget, on: monitor)
            let label = VitreusFixture.find(widget, key: "title-text").map {
                widget.text.string(widget.surface.layout.core.content(of: $0).text)
            }
            XCTAssertEqual(label ?? "", expected)
        }
        let omitted = try notchWidget(
            shell, NotchRun(size: 1, fullWidth: true, media: false), on: monitor, pieces: ["apple", "omniwm", "clock"]
        )
        XCTAssertFalse(Self.has(omitted, "title-text"))
        XCTAssertFalse(Self.has(omitted, "title-button"))
    }

    func testTheCompactTitleSwitchesAtTheMeasuredHeightBoundary() throws {
        let shell = try shell()
        let run = NotchRun(size: 1, fullWidth: true, media: false)
        let original = Self.fourteenInch()
        let widget = try notchWidget(shell, run, on: original)
        let pill = try VitreusFixture.frame(widget, key: "shell")
        let text = try VitreusFixture.frame(widget, key: "title-text")
        let unit = try XCTUnwrap(probe("""
        local units = require("../lib/vitreus/units")
        function render(ctx) return ui.text{ text = tostring(units.u) } end
        """).first.flatMap(Double.init))
        let boundary = pill.maxY - text.height - 2 * unit * run.size
        for (height, fits) in [(boundary.nextDown, true), (boundary.nextUp, false)] {
            let monitor = Monitor(
                id: original.id, displayId: original.displayId, frame: original.frame,
                visibleFrame: original.visibleFrame,
                hasNotch: true, notchRange: original.notchRange, notchHeight: height, name: original.name
            )
            let candidate = try notchWidget(shell, run, on: monitor)
            let button = try VitreusFixture.frame(candidate, key: "title-button")
            XCTAssertEqual(button.minY >= height, fits, "notch \(height), boundary \(boundary)")
        }
    }

    func testNotchTitleSnapshots() throws {
        let shell = try shell()
        let monitor = Self.fourteenInch()
        let notch = try Self.notch(of: monitor)
        for run in NotchRun.all {
            let widget = try notchWidget(shell, run, on: monitor)
            var bar = notchBar(monitor, run)
            bar.style.keyboardMode = KeyboardModeKind.window.rawValue
            VitreusFixture.show(widget, on: monitor, bar: bar)
            let button = try VitreusFixture.frame(widget, key: "title-button")
            let placement = button.minY >= notch.maxY ? "below" : "beside"
            let name = "notch-\(placement)-size-\(run.size)-\(run.fullWidth ? "full" : "natural")-\(run.media ? "media" : "title")-badge"
            XCTAssertTrue(Self.has(widget, "bar-omniwm-mode"), name)
            try exportNotch(widget, on: monitor, calendar: false, name: name)
            if run.size == NotchRun.all.map(\.size).max(), !run.media {
                let components = DateComponents(year: 2026, month: 10, day: 28, hour: 18, minute: 42)
                let shown = try XCTUnwrap(Calendar.current.date(from: components))
                widget.set("seconds") { $0.number(shown.timeIntervalSince1970) }
                widget.set("date") { $0.string("Wed 28 Oct") }
                widget.set("calendar") { writer in
                    ShellCalendar(access: "full", month: ShellCalendarMonth(
                        title: "October 2026", year: 2026, month: 10, days: 31, offset: 3, today: 28,
                        weekdays: ["M", "T", "W", "T", "F", "S", "S"], marked: []
                    ), selectedDay: "2026-10-28", reminders: ShellReminders(
                        access: "full", items: [], total: 0, error: nil
                    )).write(into: &writer)
                }
                VitreusFixture.trigger(widget.instance, "drawer-calendar", bar.monitorId)
                widget.render(bar)
                XCTAssertTrue(Self.has(widget, "calendar-clock"))
                try exportNotch(widget, on: monitor, calendar: true, name: name + "-calendar")
            }
        }
    }

    func testACompleteCompactMediaRowKeepsItsTransportHoverAndBeatTogether() throws {
        let shell = try shell()
        let run = NotchRun(size: 1, fullWidth: true, media: true)
        let original = Self.fourteenInch()
        let side = try notchWidget(shell, run, on: original)
        let pill = try VitreusFixture.frame(side, key: "shell")
        let icon = try VitreusFixture.frame(side, key: "title-play-icon")
        let units = try XCTUnwrap(probe("""
        local units = require("../lib/vitreus/units")
        function render(ctx) return ui.text{ text = tostring(units.u) } end
        """).first.flatMap(Double.init))
        let height = (pill.maxY - icon.height - 2 * units * run.size).nextDown
        let monitor = Monitor(
            id: original.id, displayId: original.displayId, frame: original.frame, visibleFrame: original.visibleFrame,
            hasNotch: true, notchRange: original.notchRange, notchHeight: height, name: original.name
        )
        let widget = try notchWidget(shell, run, on: monitor)
        VitreusFixture.settings(widget, ["visualiser": .bool(true), "size": .number(run.size)])
        var bar = VitreusFixture.bar(monitor)
        bar.style.fullWidth = run.fullWidth
        VitreusFixture.show(widget, on: monitor, bar: bar)
        let notch = try Self.notch(of: monitor)
        let button = try VitreusFixture.frame(widget, key: "title-button")
        XCTAssertGreaterThanOrEqual(button.minY, notch.maxY)
        let player = try VitreusFixture.frame(widget, key: "title-play")
        for (key, command) in [("previous", "media previous"), ("play", "media toggle"), ("next", "media next")] {
            let frame = try VitreusFixture.frame(widget, key: "title-" + key)
            XCTAssertTrue(button.contains(frame), key)
            XCTAssertTrue(button.contains(try VitreusFixture.frame(widget, key: "title-" + key + "-icon")), key)
            XCTAssertEqual(widget.surface.command(at: CGPoint(x: frame.midX, y: frame.midY)), command, key)
        }
        for name in VitreusFixture.crests("beat", phase: "close") {
            let frame = try VitreusFixture.frame(widget, key: name)
            XCTAssertEqual(frame.midX, player.midX, accuracy: Double(Float(player.midX).ulp), name)
            XCTAssertEqual(frame.midY, pill.maxY, accuracy: Double(Float(pill.maxY).ulp), name)
        }
        let action = widget.surface.layout.core.content(of: try VitreusFixture.element(widget, key: "title-button"))
            .hoverAction
        var event = ShellEvent()
        event.phase = .began
        widget.invoke(action, event: event)
        VitreusFixture.show(widget, on: monitor, bar: bar)
        Self.assertRect(try VitreusFixture.frame(widget, key: "title-tab"), button)
    }

    private func exportNotch(_ widget: ShellRenderedWidget, on monitor: Monitor, calendar: Bool, name: String) throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] != nil else { return }
        let pill = try VitreusFixture.frame(widget, key: "shell")
        let crop = CGRect(
            x: 0,
            y: 0,
            width: monitor.frame.width,
            height: calendar ? monitor.frame.height : (pill.maxY + pill.height).rounded(.up)
        )
        let scale = Int(widget.surface.scale)
        let width = Int(crop.width) * scale, height = Int(crop.height) * scale
        let bytes = try VitreusFixture.pixels(widget, crop: crop, scale: scale)
        let info = CGBitmapInfo.byteOrder32Little
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: info, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: info.rawValue
        ))
        context.setFillColor(NSColor.darkGray.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let notch = try Self.notch(of: monitor)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(
            x: notch.minX * CGFloat(scale),
            y: CGFloat(height) - notch.maxY * CGFloat(scale),
            width: notch.width * CGFloat(scale),
            height: notch.height * CGFloat(scale)
        ))
        try ShellVitreusDeskTests.write(XCTUnwrap(context.makeImage()), name: name)
    }
}
