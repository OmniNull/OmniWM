// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
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
        _ shell: URL, _ run: NotchRun, on monitor: Monitor, tray: [ShellHiddenBarItem] = [], pieces: [String]? = nil
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
        var bar = VitreusFixture.bar(monitor)
        bar.style.fullWidth = run.fullWidth
        bar.style.hidesMenuBar = true
        bar.workspaces = ["1", "2", "3"].map { id in
            ShellBarWorkspace(id: id, name: id, focused: id == "1", windows: [ShellBarItem(
                id: id, bundle: "test.app", name: "App", focused: id == "1", count: 1, hidden: 0,
                windows: [.init(id: "window-" + id, title: "Window " + id, focused: id == "1", hidden: false)]
            )])
        }
        VitreusFixture.show(widget, on: monitor, bar: bar)
        return widget
    }

    private func drawnContent(_ widget: ShellRenderedWidget) throws -> [CGRect] {
        let layout = widget.surface.layout
        let scene = widget.surface.scene
        let root = try VitreusFixture.element(widget, key: "bar-hover")
        return layout.core.elements { _ in true }.filter { element in
            var ancestor = layout.core.parent(of: element)
            while ancestor != .none, ancestor != root {
                ancestor = layout.core.parent(of: ancestor)
            }
            let kind = layout.core.kind(of: element)
            let filled = (kind == .box || kind == .group) && layout.core.paint(of: element).fill != .clear
            return ancestor == root && (inked.contains(kind) || filled)
        }.map { element in
            let frame = CGRect(layout.core.absoluteFrame(of: element))
            guard layout.core.kind(of: element) == .path else { return frame }
            let stroke = ShellLayerScene.engineQueue.sync { () -> CGRect? in
                guard let shape = scene.layers[element.slot] as? CAShapeLayer, let path = shape.path else { return nil }
                return path.boundingBoxOfPath.insetBy(dx: -shape.lineWidth / 2, dy: -shape.lineWidth / 2)
            }
            return stroke?.offsetBy(dx: frame.minX, dy: frame.minY) ?? frame
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

    func testTheIslandBarMeltsIntoTheNotchAndKeepsEveryPieceBesideIt() throws {
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
            for rect in content {
                XCTAssertTrue(rect.maxX <= notch.minX || rect.minX >= notch.maxX, "\(run.label) \(rect)")
                XCTAssertTrue(rect.minX >= pill.minX && rect.maxX <= pill.maxX, "\(run.label) \(rect)")
            }
            try assertMelt(widget, notch: notch, run.label)
            XCTAssertFalse(Self.has(level, "notch-melt"), run.label)
            if run.fullWidth {
                Self.assertRect(pill, flat, run.label)
            } else {
                XCTAssertEqual(pill.midX, notch.midX, accuracy: 0.001, run.label)
                XCTAssertEqual(
                    try VitreusFixture.frame(widget, key: "title-button").width,
                    try VitreusFixture.frame(level, key: "title-button").width, accuracy: 0.001, run.label
                )
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

    private static let pieceGroups: [[String]] = [
        ["bar-apple"], ["bar-app"], ["1", "2", "3"].map { "workspace-mark-" + $0 },
        ["title-app", "title-text", "title-previous", "title-play", "title-next"],
        ["bar-search"], ["bar-omniwm"], ["bar-controls"], ["bar-clock"], ["desk-opener"]
    ]

    private func frames(_ widget: ShellRenderedWidget, _ keys: [String]) throws -> [CGRect] {
        try keys.filter { Self.has(widget, $0) }.map { try VitreusFixture.frame(widget, key: $0) }
    }

    private func assertPiecesApart(_ widget: ShellRenderedWidget, tray: [CGRect], _ label: String) throws {
        let groups = try Self.pieceGroups.map { try frames(widget, $0) }
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
        for rect in try drawnContent(widget) {
            XCTAssertTrue(rect.maxX <= notch.minX || rect.minX >= notch.maxX, "\(label) \(rect)")
            XCTAssertTrue(rect.minX >= pill.minX && rect.maxX <= pill.maxX, "\(label) \(rect)")
        }
    }

    func testAFullTrayStaysOnScreenAndOutOfTheNotchInBothWidths() throws {
        let shell = try shell()
        let notched = Self.fourteenInch()
        let splitTray = 18
        let cappedTray = 60
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
                XCTAssertGreaterThan(try VitreusFixture.frame(widget, key: "title-app").width, 0, label)
            }
            if trayItems == splitTray {
                XCTAssertEqual(shown.count, trayItems, label)
            } else {
                XCTAssertFalse(shown.isEmpty, label)
                XCTAssertLessThan(shown.count, trayItems, label)
            }
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
}
