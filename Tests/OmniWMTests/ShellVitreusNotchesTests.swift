// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

private let unit = 1.35
private let cu = 1.5525

@MainActor
final class ShellVitreusNotchesTests: XCTestCase {
    struct Fixture {
        let widget: ShellRenderedWidget
        var settings: [String: ShellComponentValue]
        var monitor: Monitor
        var title = "A document title"
        var enabled = true
    }

    static func notched() -> Monitor {
        Monitor(
            id: .init(displayId: 95300), displayId: 95300, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1043), hasNotch: true, notchRange: 860 ... 1060,
            notchHeight: 32, name: VitreusFixture.primary
        )
    }

    func fixture(monitor: Monitor = VitreusFixture.monitor(), animations: Bool = false) throws -> Fixture {
        let shell = try VitreusFixture.shell()
        addTeardownBlock { VitreusFixture.remove(shell) }
        let source = try VitreusFixture.source(shell)
        let config = try VitreusFixture.config(shell)
        let widget = try ShellRenderedWidget(
            name: source.chunk, source: source.main,
            directories: [try XCTUnwrap(config.widget("vitreus")).deletingLastPathComponent()] + config.directories,
            modules: source.modules, chunk: source.chunk, scale: 1,
            resources: VitreusFixture.resources(shell, animations: animations),
            fonts: ShellFontLibrary.shared.fonts(in: source.fontFolders),
            memoryLimit: ShellWidgetPackage.memoryLimit, moduleLimit: source.moduleLimit
        )
        widget.configure(ShellComponentCatalog.configurationBytes(
            instances: source.components, descriptors: source.componentDescriptors
        ))
        widget.set("clock") { $0.string("6:42 pm") }
        widget.set("date") { $0.string("Tue 28") }
        widget.set("app") { $0.string("Test App") }
        widget.set("battery") { $0.number(68) }
        widget.set("charging") { $0.bool(false) }
        widget.set("hiddenBar") { ShellHiddenBarData(items: []).write(into: &$0) }
        let result = Fixture(widget: widget, settings: ["layout": .string("seg")], monitor: monitor)
        show(result)
        return result
    }

    func show(_ fixture: Fixture) {
        VitreusFixture.settings(fixture.widget, fixture.settings)
        fixture.widget.set("title") { $0.string(fixture.title) }
        fixture.widget.set("seconds") { $0.number(1000) }
        fixture.widget.set("island") { VitreusFixture.island(fixture.monitor).write(to: &$0) }
        fixture.widget.render(bar(fixture))
        fixture.widget.surface.view.frame = CGRect(origin: .zero, size: fixture.widget.surface.size)
    }

    func bar(_ fixture: Fixture) -> ShellBarData {
        var bar = VitreusFixture.bar(fixture.monitor, enabled: fixture.enabled)
        bar.workspaces = ["1", "2", "3"].map { id in
            ShellBarWorkspace(id: id, name: id, focused: id == "1", windows: [ShellBarItem(
                id: id, bundle: "test.app", name: "App", focused: id == "1", count: 1, hidden: 0,
                windows: [.init(id: "window-" + id, title: "Window " + id, focused: id == "1", hidden: false)]
            )])
        }
        return bar
    }

    func has(_ fixture: Fixture, _ name: String) -> Bool {
        ShellVitreusBarTests.has(fixture.widget, name)
    }

    func frame(_ fixture: Fixture, _ name: String) throws -> CGRect {
        try VitreusFixture.frame(fixture.widget, key: name)
    }

    func trigger(_ fixture: Fixture, _ name: String) {
        VitreusFixture.trigger(fixture.widget.instance, name, VitreusFixture.bar(fixture.monitor).monitorId)
        show(fixture)
    }

    func hover(_ fixture: Fixture, at point: CGPoint?) {
        let start = fixture.widget.events.count
        fixture.widget.surface.hover(at: point)
        for event in fixture.widget.events.dropFirst(start) where event.action & OMNI_ACTION_HANDLER != 0 {
            fixture.widget.invoke(event.action, event: event.event)
        }
        show(fixture)
    }

    func morph(_ fixture: Fixture, _ name: String) throws -> ShellMorphRecipe {
        let paint = fixture.widget.surface.layout.core.paint(of: try VitreusFixture.element(fixture.widget, key: name))
        return try XCTUnwrap(ShellMorphRecipe(fixture.widget.text.string(paint.morph)), name)
    }

    func clockWidth(_ fixture: Fixture) throws -> CGFloat {
        try frame(fixture, "bar-clock").width - 8 * unit
    }

    func middle(_ fixture: Fixture, tray: CGFloat = 0) throws -> (from: CGFloat, to: CGFloat) {
        let clock = try clockWidth(fixture)
        let room = tray > 0 ? tray + 12 * unit : 0
        let left = 960 - (164 * unit + room) / 2 - clock / 2
        return (left - 26 * unit, left + clock + 164 * unit + room + 26 * unit)
    }
}

extension ShellVitreusNotchesTests {
    func testThreePiecesTakeTheVitreusSegmentGeometryAndTheTitleSlotStaysFixed() throws {
        var fixture = try fixture()
        XCTAssertEqual(try frame(fixture, "bar-clock").midX, 960 - 164 * unit / 2, accuracy: 0.001)
        let span = try middle(fixture)
        let expected = [
            ("notch-left", CGRect(x: -12 * unit, y: -12 * unit, width: 175.5 * unit, height: 48 * unit)),
            ("notch-middle", CGRect(x: span.from, y: -12 * unit, width: span.to - span.from, height: 48 * unit)),
            ("notch-right", CGRect(x: 1920 - 116 * unit, y: -12 * unit, width: 128 * unit, height: 48 * unit))
        ]
        let glass = try VitreusFixture.element(fixture.widget, key: "bar")
        for (key, rect) in expected {
            let handle = try VitreusFixture.element(fixture.widget, key: key)
            XCTAssertEqual(fixture.widget.surface.layout.core.parent(of: handle), glass, key)
            ShellVitreusBarTests.assertRect(try frame(fixture, key), rect, key)
            let shape = try XCTUnwrap(ShellLayerScene.engineQueue.sync {
                fixture.widget.surface.scene.glassShapes[handle.slot]
            }, key)
            XCTAssertEqual(shape.radius, 48 * unit * 0.34, accuracy: 0.001, key)
        }
        let title = try frame(fixture, "title-button")
        XCTAssertEqual(title.width, 150 * unit, accuracy: 0.001)
        XCTAssertEqual(title.minX, span.from + 26 * unit + (try clockWidth(fixture)) + 14 * unit, accuracy: 0.001)
        XCTAssertEqual(
            try frame(fixture, "title-text").minX, (title.minX + 6 * unit + 0.5).rounded(.down), accuracy: 0.001
        )
        let controls = try frame(fixture, "bar-controls")
        let logo = try frame(fixture, "bar-omniwm")
        let search = try frame(fixture, "bar-search")
        XCTAssertEqual(controls.midX, 1920 - 32.5 * unit, accuracy: 0.001)
        XCTAssertEqual(logo.midX, 1920 - 58.5 * unit, accuracy: 0.001)
        XCTAssertEqual(search.midX, 1920 - 84 * unit, accuracy: 0.001)
        XCTAssertEqual(try frame(fixture, "workspace-overview").midX, 36 * unit, accuracy: 0.001)
        for key in ["bar-controls", "bar-clock", "title-button"] {
            XCTAssertEqual(try frame(fixture, key).minY, 0, accuracy: 0.001, key)
            XCTAssertEqual(try frame(fixture, key).height, 36 * unit, accuracy: 0.001, key)
        }
        let before = try frame(fixture, "notch-middle")
        fixture.title = "A much longer document title that runs past the fixed segment title"
        show(fixture)
        ShellVitreusBarTests.assertRect(try frame(fixture, "notch-middle"), before, "fixed title")
        XCTAssertEqual(try frame(fixture, "title-button").width, 150 * unit, accuracy: 0.001)
    }

    func testPieceWidthsSpringAndTheSegBodyKeepsOneBlendAndTheThinFrame() throws {
        let fixture = try fixture()
        let glass = try VitreusFixture.element(fixture.widget, key: "bar")
        let layout = fixture.widget.surface.layout
        let recipe = try XCTUnwrap(ShellGlassRecipe(fixture.widget.text.string(layout.core.content(of: glass).text)))
        XCTAssertEqual(recipe.blend, 28 * unit, accuracy: 1e-6)
        for key in ["notch-left", "notch-middle", "notch-right"] {
            let shape = try VitreusFixture.element(fixture.widget, key: key)
            guard case let .spring(response, bounce)? = fixture.widget.surface.animation(for: shape)?.motion else {
                return XCTFail("\(key) needs the calm width spring")
            }
            XCTAssertEqual(response, 0.513, accuracy: 1e-6, key)
            XCTAssertEqual(bounce, 0.06, accuracy: 1e-6, key)
            let reveal =
                try XCTUnwrap(ShellRevealRecipe(fixture.widget.text.string(layout.core.paint(of: shape).reveal)))
            XCTAssertEqual(reveal.response, 0.513, accuracy: 1e-6, key)
            let morph = try morph(fixture, key)
            XCTAssertEqual(morph.stop(at: 1).height, 1, key)
            XCTAssertEqual(morph.stop(at: 0).height, 20 * unit / (48 * unit), accuracy: 1e-6, key)
            XCTAssertEqual(morph.stop(at: 0).dy, -(28 * unit) / 2, accuracy: 1e-6, key)
        }
        let handle = try VitreusFixture.element(fixture.widget, key: "frame")
        let ring = try XCTUnwrap(ShellLayerScene.engineQueue.sync {
            fixture.widget.surface.scene.glassShapes[handle.slot]
        })
        let hole = ring.rect.insetBy(dx: ring.thickness, dy: ring.thickness)
        for value in [hole.minX, 1920 - hole.maxX, hole.minY, 1080 - hole.maxY] {
            XCTAssertEqual(value, 8 * unit, accuracy: 0.001)
        }
        XCTAssertGreaterThanOrEqual(-ring.rect.minX, 2 * 28 * unit)
        let before = try frame(fixture, "notch-middle")
        let items = (1 ... 2).map {
            ShellHiddenBarItem(id: "item-\($0)", name: "Item \($0)", image: nil, width: 18, height: 18)
        }
        fixture.widget.set("hiddenBar") { ShellHiddenBarData(items: items).write(into: &$0) }
        show(fixture)
        let tray = 42 * unit
        let span = try middle(fixture, tray: tray)
        let after = try frame(fixture, "notch-middle")
        XCTAssertEqual(after.minX, span.from, accuracy: 0.001)
        XCTAssertEqual(after.maxX, span.to, accuracy: 0.001)
        XCTAssertEqual(after.width - before.width, tray + 12 * unit, accuracy: 0.001)
        XCTAssertEqual(try frame(fixture, "tray-item-1").midX - 9 * unit, span.to - 26 * unit - tray, accuracy: 0.5)
    }

    func testRightTabOpensTheDeskWhileTheOpenerAndTitleTabStayHidden() throws {
        let fixture = try fixture()
        XCTAssertFalse(has(fixture, "desk-opener"))
        XCTAssertFalse(has(fixture, "shell"))
        XCTAssertFalse(has(fixture, "frame-hover-top"))
        for name in ["left", "right"] {
            XCTAssertEqual(
                try frame(fixture, "frame-hover-" + name).midY,
                (46 * unit + 1080 - 8 * unit) / 2,
                accuracy: 0.001
            )
        }
        XCTAssertEqual(try frame(fixture, "frame-hover-bottom").midX, 960, accuracy: 0.001)
        let hot = try frame(fixture, "frame-hover-right")
        hover(fixture, at: CGPoint(x: hot.midX, y: hot.midY))
        XCTAssertTrue(has(fixture, "frame-tab-right"))
        let hit = fixture.widget.surface.layout.core.content(of: try VitreusFixture.element(
            fixture.widget,
            key: "frame-hit-right"
        ))
        let display = VitreusFixture.bar(fixture.monitor).monitorId
        XCTAssertEqual(fixture.widget.text.string(hit.action), "shell trigger vitreus desk-open " + display)
        hover(fixture, at: nil)
        trigger(fixture, "desk-open")
        XCTAssertTrue(has(fixture, "desk"))
        XCTAssertFalse(has(fixture, "frame-hover-right"))
        let title = try frame(fixture, "title-button")
        hover(fixture, at: CGPoint(x: title.midX, y: title.midY))
        XCTAssertFalse(has(fixture, "title-tab"))
    }

    func testHoverAndHitsCoverOnlyThePiecesAndTheGapsStayClickThrough() throws {
        let fixture = try fixture()
        XCTAssertFalse(has(fixture, "bar-hover"))
        let span = try middle(fixture)
        let regions = fixture.widget.surface.islandRegions()
        let gaps = [CGPoint(x: 500, y: 30), CGPoint(x: 1400, y: 30), CGPoint(x: 960, y: 540)]
        for point in gaps {
            XCTAssertFalse(regions.contains { $0.contains(point) }, "\(point)")
            XCTAssertFalse(fixture.widget.surface.containsShape(at: point), "\(point)")
        }
        for point in [CGPoint(x: 500, y: 5), CGPoint(x: 210, y: 30), CGPoint(x: span.from + 4, y: 30)] {
            XCTAssertTrue(fixture.widget.surface.containsShape(at: point), "\(point)")
        }
        let areas = [
            ("left", CGRect(x: 0, y: 0, width: 163.5 * unit, height: 36 * unit)),
            ("middle", CGRect(x: span.from, y: 0, width: span.to - span.from, height: 36 * unit)),
            ("right", CGRect(x: 1920 - 116 * unit, y: 0, width: 116 * unit, height: 36 * unit))
        ]
        for (name, rect) in areas {
            ShellVitreusBarTests.assertRect(try frame(fixture, "bar-hover-" + name), rect, name)
        }
        let slot = try VitreusFixture.element(fixture.widget, key: "battery-track").slot
        func opacity() throws -> Float {
            try ShellLayerScene.engineQueue.sync {
                try XCTUnwrap(fixture.widget.surface.scene.layers[slot]).opacity
            }
        }
        XCTAssertEqual(try opacity(), 0)
        ShellVitreusBarTests.assertRect(
            try frame(fixture, "battery-track"),
            CGRect(
                x: span.from + 7 * unit,
                y: 18 * unit - 22 * unit * 0.7 / 2,
                width: span.to - span.from - 14 * unit,
                height: 22 * unit * 0.7
            ),
            "gauge"
        )
        hover(fixture, at: CGPoint(x: 210, y: 30))
        XCTAssertGreaterThan(try opacity(), 0)
        hover(fixture, at: gaps[0])
        XCTAssertEqual(try opacity(), 0)
        hover(fixture, at: CGPoint(x: 1780, y: 30))
        XCTAssertGreaterThan(try opacity(), 0)
    }

    func testEachPieceDrawsItsOwnSlotsOnADisplayWithoutANotch() throws {
        let fixture = try fixture()
        let owners = [
            ("left", ["workspace-overview"]), ("middle", ["bar-clock", "title-button"]),
            ("right", ["bar-search", "bar-omniwm", "bar-controls"])
        ]
        for (name, keys) in owners {
            let area = try VitreusFixture.element(fixture.widget, key: "bar-hover-" + name)
            let piece = try frame(fixture, "bar-hover-" + name)
            for key in keys {
                let rect = try frame(fixture, key)
                let item = try VitreusFixture.element(fixture.widget, key: key)
                XCTAssertTrue(fixture.widget.surface.isWithin(item, area), key)
                XCTAssertTrue(piece.contains(CGPoint(x: rect.midX, y: rect.midY)), key)
            }
        }
    }

    func testLeavingNotchesRetiresThePiecesBehindTheClosingRing() throws {
        var fixture = try fixture(animations: true)
        let scene = fixture.widget.surface.scene
        let renderer = try ShellLayerScene.engineQueue.sync {
            scene.container.frame = CGRect(origin: .zero, size: fixture.widget.surface.size)
            let renderer = try ShellOffscreenRenderer(root: scene.container, width: 1920, height: 1080)
            scene.container.speed = 0
            scene.container.timeOffset = CACurrentMediaTime()
            return renderer
        }
        fixture.settings["layout"] = .string("island")
        show(fixture)
        XCTAssertFalse(has(fixture, "notch-middle"))
        try ShellLayerScene.engineQueue.sync {
            let retiring = scene.shapeTracks.entries.values.filter { $0.carrier != nil }
            XCTAssertEqual(retiring.count { $0.base.target.kind == 2 }, 1)
            XCTAssertEqual(retiring.count { $0.base.target.kind == 0 }, 3)
            XCTAssertTrue(retiring.allSatisfy { $0.plan?.target == 0 && !$0.animations.isEmpty })
            let ring = try XCTUnwrap(retiring.first { $0.base.target.kind == 2 })
            XCTAssertTrue(scene.layers[ring.body]?.sublayers?.first === ring.carrier)
            XCTAssertNil(try XCTUnwrap(scene.glassBodies[ring.body]).failure)
            _ = try renderer.render()
        }
    }

    func testADisabledBarLeavesOnlyTheThinSegFrame() throws {
        var fixture = try fixture()
        fixture.enabled = false
        show(fixture)
        for name in ["left", "middle", "right"] {
            XCTAssertFalse(has(fixture, "notch-" + name), name)
            XCTAssertFalse(has(fixture, "bar-hover-" + name), name)
        }
        XCTAssertFalse(has(fixture, "frame-hover-right"))
        XCTAssertTrue(has(fixture, "frame"))
        XCTAssertFalse(fixture.widget.surface.containsShape(at: CGPoint(x: 210, y: 30)))
        XCTAssertTrue(fixture.widget.surface.containsShape(at: CGPoint(x: 210, y: 5)))
    }

    func testDrawersHangFromTheirPiecesReachTheScreenEdgeAndRunNoEdgeRipples() throws {
        let fixture = try fixture()
        trigger(fixture, "drawer-calendar")
        let calendar = try frame(fixture, "drawer-frame-calendar")
        XCTAssertEqual(calendar.midX, 960, accuracy: 0.001)
        XCTAssertEqual(calendar.minY, -12 * unit, accuracy: 0.001)
        XCTAssertEqual(calendar.width, 463 * cu, accuracy: 0.001)
        XCTAssertEqual(calendar.height, 28 * unit + 379 * cu + 30 * unit, accuracy: 0.001)
        let content = try frame(fixture, "drawer-content-calendar")
        XCTAssertEqual(content.midX, 960, accuracy: 0.001)
        XCTAssertEqual(content.minY, 46 * unit - 0.5 * cu, accuracy: 0.001)
        let opening = try morph(fixture, "drawer-frame-calendar")
        XCTAssertEqual(opening.stop(at: 0).dx, 0, accuracy: 0.001)
        XCTAssertEqual(opening.anchor.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(opening.anchor.y, 0)
        trigger(fixture, "drawer-controls")
        trigger(fixture, "drawer-close")
        trigger(fixture, "drawer-controls")
        let controls = try frame(fixture, "drawer-frame-controls")
        let centre = 1920 - 8 * unit - 162.5 * cu
        XCTAssertEqual(controls.midX, centre + 7 * unit, accuracy: 0.001)
        XCTAssertEqual(controls.minY, -12 * unit, accuracy: 0.001)
        let slide = try morph(fixture, "drawer-frame-controls").stop(at: 0).dx
        XCTAssertEqual(slide, 1920 - 32.5 * unit - centre, accuracy: 0.001)
        for name in ["controls", "calendar"] {
            for phase in ["open", "close"] {
                for sign in ["-1", "1"] {
                    XCTAssertFalse(has(fixture, "drawer-ripple-\(name)-\(phase)-\(sign)"), "\(name) \(phase) \(sign)")
                }
            }
        }
        let island = ShellVitreusDrawerTests.island(fixture.widget, on: fixture.monitor)
        defer { island.close() }
        for name in ["left", "middle", "right"] {
            for point in ShellVitreusDrawerTests.samples(try frame(fixture, "bar-hover-" + name)) {
                XCTAssertEqual(ShellVitreusDrawerTests.press(island, fixture.widget, at: point), [true], "\(point)")
                show(fixture)
            }
        }
        XCTAssertTrue(has(fixture, "drawer-frame-controls"))
        XCTAssertEqual(ShellVitreusDrawerTests.press(island, fixture.widget, at: CGPoint(x: 500, y: 30)), [false])
        show(fixture)
        XCTAssertFalse(has(fixture, "drawer-frame-controls"))
    }

    func testSegClockDrawsTheShortLineBetweenTheDayAndTheMeridiem() throws {
        let fixture = try fixture()
        let zone = try frame(fixture, "bar-clock")
        let day = try frame(fixture, "clock-day")
        let meridiem = try frame(fixture, "clock-meridiem")
        let column = max(day.width, meridiem.width)
        let right = zone.maxX - 4 * unit
        let layout = fixture.widget.surface.layout
        let group = try VitreusFixture.element(fixture.widget, key: "clock-group")
        let passes = layout.core.elements { _ in true }
            .filter { layout.core.parent(of: $0) == group && layout.core.kind(of: $0) == .path }
        XCTAssertEqual(passes.count, 2)
        let main = try XCTUnwrap(passes.first { layout.core.paint(of: $0).opacity > 0.3 })
        let numbers = ShellVitreusBarTests.numbers(fixture.widget.text.string(layout.core.content(of: main).text)
            .replacingOccurrences(of: "M", with: " ").replacingOccurrences(of: "Q", with: " "))
        XCTAssertEqual(numbers.count, 10)
        XCTAssertEqual(zone.minX + numbers[4], right - column / 2, accuracy: 0.25)
        XCTAssertEqual(numbers[5], 18 * unit - 0.5, accuracy: 0.25)
        XCTAssertEqual(numbers[8] - numbers[0], 0.6 * column, accuracy: 0.5)
        XCTAssertLessThan(day.midY, numbers[5])
        XCTAssertGreaterThan(meridiem.midY, numbers[5])
    }

    func testANotchLowersOnlyTheMiddlePieceContentAndItsDrawersBelowIt() throws {
        let plain = try fixture()
        let notched = try fixture(monitor: Self.notched())
        let top = 32.0
        let span = try middle(notched)
        ShellVitreusBarTests.assertRect(
            try frame(notched, "notch-middle"),
            CGRect(x: span.from, y: -12 * unit, width: span.to - span.from, height: 12 * unit + top + 36 * unit),
            "middle"
        )
        for key in ["notch-left", "notch-right", "bar-controls", "workspace-overview"] {
            ShellVitreusBarTests.assertRect(try frame(notched, key), try frame(plain, key), key)
        }
        XCTAssertEqual(try frame(plain, "notch-middle").minY, -12 * unit, accuracy: 0.001)
        XCTAssertEqual(try frame(notched, "bar-clock").minY, top, accuracy: 0.001)
        XCTAssertEqual(try frame(notched, "clock-hour").midY - top, try frame(plain, "clock-hour").midY, accuracy: 1)
        XCTAssertEqual(try frame(notched, "bar-hover-middle").minY, top, accuracy: 0.001)
        trigger(notched, "drawer-calendar")
        XCTAssertEqual(try frame(notched, "drawer-frame-calendar").minY, -12 * unit, accuracy: 0.001)
        XCTAssertEqual(try frame(notched, "drawer-content-calendar").minY, top + 46 * unit - 0.5 * cu, accuracy: 0.001)
        trigger(notched, "drawer-controls")
        trigger(notched, "drawer-close")
        trigger(notched, "drawer-controls")
        XCTAssertEqual(try frame(notched, "drawer-frame-controls").minY, -12 * unit, accuracy: 0.001)
    }

    func testSegBodySnapshotHasGlassOnThePiecesAndClearGaps() throws {
        let fixture = try fixture()
        let body = try VitreusFixture.body(fixture.widget, key: "bar")
        guard ShellLayerScene.engineQueue.sync(execute: { body.nativeAvailable }) else {
            throw XCTSkip("Native glass is unavailable")
        }
        let crop = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let full = try VitreusFixture.pixels(fixture.widget, crop: crop, scale: 1)
        let bare = try VitreusFixture.pixels(fixture.widget, crop: crop, scale: 1, shadowless: true)
        func alpha(_ pixels: [UInt8], _ x: CGFloat, _ y: CGFloat) -> UInt8 {
            pixels[(Int(y) * 1920 + Int(x)) * 4 + 3]
        }
        let span = try middle(fixture)
        for point in [
            CGPoint(x: 6, y: 30), CGPoint(x: 210, y: 40), CGPoint(x: span.from + 30, y: 40),
            CGPoint(x: span.to - 30, y: 40), CGPoint(x: 1790, y: 40), CGPoint(x: 1915, y: 40), CGPoint(x: 500, y: 4),
            CGPoint(x: 4, y: 540), CGPoint(x: 960, y: 1076)
        ] {
            XCTAssertGreaterThan(alpha(bare, point.x, point.y), 40, "\(point)")
        }
        for point in [
            CGPoint(x: 500, y: 40), CGPoint(x: 1400, y: 40), CGPoint(x: 210, y: 70), CGPoint(x: 960, y: 80),
            CGPoint(x: 960, y: 540)
        ] {
            XCTAssertEqual(alpha(bare, point.x, point.y), 0, "\(point)")
        }
        for point in [CGPoint(x: 500, y: 60), CGPoint(x: 960, y: 540)] {
            XCTAssertEqual(alpha(full, point.x, point.y), 0, "\(point)")
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(full) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 1920, height: 1080, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1920 * 4,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo.byteOrder32Little
                .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        try ShellVitreusDeskTests.write(image, name: "vitreus-frame-seg")
    }
}
