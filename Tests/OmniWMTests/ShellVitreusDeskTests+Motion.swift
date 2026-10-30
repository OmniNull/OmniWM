// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

private struct DeskScreen {
    let width: Double
    let height: Double
    let usable: Double
}

@MainActor
extension ShellVitreusDeskTests {
    private static let inset = 6.5 / 353
    private static let corners: [(edge: String, mask: UInt8)] = [("nw", 5), ("ne", 6), ("sw", 9), ("se", 10)]

    private static func lift(_ at: Double) -> Double {
        min(1, 1.6 * at) + max(0, at - 1) * 0.6
    }

    private static func bell(_ at: Double) -> Double {
        let progress = min(1, at)
        return 4 * progress * (1 - progress)
    }

    private static func assertSpring(_ motion: ShellMotion?, _ response: Double, _ bounce: Double, line: UInt = #line) {
        guard case let .spring(actual, spring)? = motion else {
            return XCTFail("\(String(describing: motion))", line: line)
        }
        XCTAssertEqual(actual, response, accuracy: 0.0001, line: line)
        XCTAssertEqual(spring, bounce, accuracy: 0.0001, line: line)
    }

    private static func assertRect(_ actual: CGRect, _ expected: CGRect, accuracy: CGFloat = 0.01, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, line: line)
    }

    private func commit(_ widget: ShellRenderedWidget) throws -> String {
        let desk = try VitreusFixture.element(widget, key: "desk")
        return widget.text.string(widget.surface.layout.core.content(of: desk).manipulationCommit)
    }

    private func recipe(_ widget: ShellRenderedWidget, _ name: String) throws -> ShellManipulationRecipe {
        let handle = try VitreusFixture.element(widget, key: name)
        let content = widget.surface.layout.core.content(of: handle)
        return try XCTUnwrap(ShellManipulationRecipe(widget.text.string(content.gestureTrack)), name)
    }

    private func presence(_ widget: ShellRenderedWidget, _ reference: UInt32) throws -> ShellPresenceRecipe {
        try XCTUnwrap(ShellPresenceRecipe(widget.text.string(reference)))
    }

    private static func expectedRows(_ screen: DeskScreen) -> [[Double]] {
        let rs = min(max(screen.height / 1350, 0.55), 1)
        let du = 1.5525 * rs
        let right = screen.usable - 7.5 * du
        let home = CGPoint(x: right - 346.5 * du, y: max(32, screen.height / 2 - 230 * du))
        let bounds = CGRect(x: 8 * du, y: 8 * du, width: right - 14.5 * du, height: screen.height - 16 * du)
        let places = [
            CGRect(x: home.x - 100, y: home.y + 40, width: 0.5, height: 0),
            CGRect(x: bounds.minX, y: bounds.minY, width: 0.5, height: 0),
            CGRect(x: home.x, y: bounds.maxY - 460 * du, width: 1, height: 0)
        ]
        return places.map { place in
            let scale = place.width
            return [
                scale, du * scale, rs * scale, 35.1 * scale, place.minX - 6.5 * du * scale, place.minY,
                353 * du * scale, 460 * du * scale, bounds.minX, bounds.minY, bounds.width, bounds.height, 0, 0, 0,
                80 * du, 1, 0
            ]
        }
    }

    private func assertCorner(
        _ widget: ShellRenderedWidget, _ corner: (edge: String, mask: UInt8), rect: CGRect, du: CGFloat, bounds: CGRect
    ) throws {
        let name = "resize-\(corner.edge)"
        let scale = try recipe(widget, name)
        XCTAssertEqual(scale.mode, .scale, name)
        XCTAssertEqual(scale.resizeMask, corner.mask, name)
        XCTAssertEqual(scale.inset.width, Self.inset, accuracy: 1e-6)
        Self.assertRect(scale.bounds, bounds)
        XCTAssertEqual(scale.minimum.width, rect.width / 2, accuracy: 0.01, name)
        XCTAssertEqual(scale.minimum.height, rect.height / 2, accuracy: 0.01, name)
        XCTAssertEqual(scale.maximum.width, rect.width, accuracy: 0.01, name)
        let frame = try VitreusFixture.frame(widget, key: name)
        XCTAssertEqual(frame.midX, rect.minX + (corner.mask & 2 != 0 ? 339 : 14) * du, accuracy: 0.01, name)
        XCTAssertEqual(frame.midY, rect.minY + (corner.mask & 8 != 0 ? 446 : 14) * du, accuracy: 0.01, name)
        XCTAssertEqual(frame.width, 28 * du, accuracy: 0.01, name)
    }

    func testUnitsLayTheDeskOutAtItsPlacementScaleWithinBoundsFromHome() throws {
        let screens = [
            DeskScreen(width: 1920, height: 1080, usable: 1920), DeskScreen(width: 1440, height: 900, usable: 1440),
            DeskScreen(width: 1280, height: 720, usable: 1280), DeskScreen(width: 2560, height: 1440, usable: 2560),
            DeskScreen(width: 1920, height: 1080, usable: 1840)
        ]
        let places = "{ { dx = -100, dy = 40, s = 0.5 }, { dx = -5000, dy = -5000, s = 0.2 }, { dx = 500, dy = 9000, s = 3 } }"
        let rows = screens.map { "{ \($0.width), \($0.height), \($0.usable) }" }.joined(separator: ", ")
        let probe = try VitreusFixture.probe(shell(), """
        local units = require("../lib/vitreus/units")
        function render(ctx)
            local lines = {}
            for _, size in { \(rows) } do
                local island = { size = { w = size[1], h = size[2] },
                    usableRect = { x = 0, y = 32, w = size[3], h = size[2] - 32 } }
                for _, place in \(places) do
                    local g = units.desk(island, nil, place)
                    local e, b = g.envelope, g.bounds
                    local back = units.placed(g, e)
                    local away = { x = g.home.x, y = g.home.y + 81 * g.base.du, w = g.home.w, h = g.home.h }
                    lines[#lines + 1] = table.concat({ g.s, g.k.du, g.k.rs, g.bodyRadius, e.x, e.y, e.w, e.h, b.x, b.y,
                        b.w, b.h, back.dx - g.place.dx, back.dy - g.place.dy, back.s - g.s, 80 * g.base.du,
                        if units.near(g, g.home) then 1 else 0, if units.near(g, away) then 1 else 0 }, " ")
                end
            end
            return ui.text{ text = table.concat(lines, ";") }
        end
        """)
        probe.render(ShellBarData())
        let text = try XCTUnwrap(probe.strings().first)
        let values = text.split(separator: ";").map { $0.split(separator: " ").compactMap { Double($0) } }
        let expected = screens.flatMap(Self.expectedRows)
        XCTAssertEqual(values.count, expected.count)
        for (index, (row, target)) in zip(values, expected).enumerated() {
            XCTAssertEqual(row.count, target.count, "\(index)")
            for (value, number) in zip(row, target) {
                XCTAssertEqual(value, number, accuracy: 0.001, "\(index)")
            }
            XCTAssertLessThanOrEqual(row[4] + row[6] * (1 - Self.inset), row[8] + row[10] + 0.001, "\(index)")
        }
        for (index, value) in [(6, 219.22), (7, 285.66), (3, 17.55), (15, 99.36)] {
            XCTAssertEqual(values[0][index], value, accuracy: 0.01)
        }
        XCTAssertEqual(values[12][10] + values[12][8], 1840 - 14 * 1.242, accuracy: 0.001)
    }

    func testTheDeskDeclaresFollowGripHandlesCursorsAndCloseAboveTheCorner() throws {
        let widget = try VitreusFixture.desk(shell())
        let surface = widget.surface
        let layout = surface.layout
        let (rect, du) = Self.envelope(width: 1920, height: 1080)
        let desk = try VitreusFixture.element(widget, key: "desk")
        Self.assertSpring(
            ShellMotion(recipe: widget.text.string(layout.core.content(of: desk).manipulationFollow)), 0.363, 0.42
        )
        XCTAssertEqual(layout.core.content(of: desk).manipulationCommit, 0)
        let bounds = CGRect(x: 8 * du, y: 8 * du, width: 1920 - 22 * du, height: 1080 - 16 * du)
        let grip = try VitreusFixture.element(widget, key: "grip")
        XCTAssertEqual(layout.core.content(of: grip).gesture.axis, .free)
        XCTAssertEqual(layout.core.content(of: grip).gesture.threshold, 1)
        XCTAssertNotEqual(layout.core.content(of: grip).action, 0)
        let move = try recipe(widget, "grip")
        XCTAssertEqual(move.mode, .move)
        XCTAssertEqual(move.target, VitreusFixture.key("desk"))
        XCTAssertEqual(move.inset.width, Self.inset, accuracy: 1e-6)
        XCTAssertEqual(move.inset.height, 0)
        Self.assertRect(move.bounds, bounds)
        Self.assertRect(CGRect(origin: .zero, size: move.minimum), CGRect(origin: .zero, size: rect.size))
        Self.assertRect(CGRect(origin: .zero, size: move.maximum), CGRect(origin: .zero, size: rect.size))
        for corner in Self.corners {
            try assertCorner(widget, corner, rect: rect, du: du, bounds: bounds)
        }
        for (name, cursor) in [
            ("grip", ElementCursor.grab), ("resize-se", .grab), ("close", .pointer), ("tab-pad", .pointer),
            ("tab-focus", .pointer)
        ] {
            XCTAssertEqual(try layout.core.content(of: VitreusFixture.element(widget, key: name)).cursor, cursor, name)
        }
        let overlap = CGPoint(x: rect.minX + 329 * du, y: rect.minY + 27 * du)
        XCTAssertTrue(try VitreusFixture.frame(widget, key: "resize-ne").contains(overlap))
        XCTAssertTrue(try VitreusFixture.frame(widget, key: "close").contains(overlap))
        XCTAssertEqual(
            surface.element(at: overlap) { $0.acceptsPointer },
            try VitreusFixture.element(widget, key: "close")
        )
        try VitreusFixture.drag(widget, key: "grip", by: CGVector(dx: -200 * du, dy: 0))
        XCTAssertTrue(try commit(widget).hasPrefix("placement-"))
    }

    func testGripDropsSnapHomeWithinEightyUnitsAndKeepTheDroppedRectBeyond() throws {
        let widget = try VitreusFixture.desk(shell())
        let (home, du) = Self.envelope(width: 1920, height: 1080)
        var commits: Set<String> = []
        for (offset, snaps) in [
            (CGVector(dx: -50 * du, dy: 0), true), (CGVector(dx: -56 * du, dy: 56 * du), true),
            (CGVector(dx: -200 * du, dy: 60 * du), false), (CGVector(dx: 0, dy: 81 * du), false)
        ] {
            try VitreusFixture.drag(widget, key: "grip", by: offset)
            XCTAssertNil(widget.surface.manipulation)
            let expected = snaps ? home : home.offsetBy(dx: offset.dx, dy: offset.dy)
            Self.assertRect(try VitreusFixture.frame(widget, key: "desk"), expected)
            commits.insert(try commit(widget))
            try VitreusFixture.drag(widget, key: "grip", by: CGVector(dx: -offset.dx, dy: -offset.dy))
            Self.assertRect(try VitreusFixture.frame(widget, key: "desk"), home)
            commits.insert(try commit(widget))
        }
        XCTAssertEqual(commits.count, 8)
        XCTAssertTrue(commits.allSatisfy { $0.hasPrefix("placement-") })
    }

    func testCornerScaleKeepsTheOppositeContentCornerAndAGripDropNearHomeRestoresFullSize() throws {
        let widget = try VitreusFixture.desk(shell())
        let (home, du) = Self.envelope(width: 1920, height: 1080)
        let corner = CGPoint(x: home.maxX - home.width * Self.inset, y: home.minY)
        try VitreusFixture.drag(widget, key: "resize-sw", by: CGVector(dx: 160 * du, dy: -160 * du))
        let rect = try VitreusFixture.frame(widget, key: "desk")
        XCTAssertEqual(rect.width / home.width, 0.6, accuracy: 1e-6)
        XCTAssertEqual(rect.height / home.height, 0.6, accuracy: 1e-6)
        XCTAssertEqual(rect.maxX - rect.width * Self.inset, corner.x, accuracy: 0.01)
        XCTAssertEqual(rect.minY, corner.y, accuracy: 0.01)
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "grip").width, 294 * du * 0.6, accuracy: 0.01)
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "chip-15").height, 32 * du * 0.6, accuracy: 0.01)
        let exit = try presence(
            widget,
            widget.surface.layout.core.paint(of: VitreusFixture.element(widget, key: "desk")).exit
        )
        XCTAssertEqual(exit.scale, 1 / 0.6, accuracy: 1e-4)
        XCTAssertEqual(exit.offset.x, home.minX - rect.minX, accuracy: 0.01)
        XCTAssertEqual(exit.offset.y, home.minY - rect.minY, accuracy: 0.01)
        XCTAssertEqual(exit.anchor, .zero)
        XCTAssertEqual(exit.opacity, 1)
        Self.assertSpring(exit.motion, 0.363, 0.42)
        try VitreusFixture.drag(widget, key: "resize-ne", by: CGVector(dx: -60 * du, dy: 60 * du))
        let smaller = try VitreusFixture.frame(widget, key: "desk")
        XCTAssertEqual(smaller.width / home.width, 0.5, accuracy: 1e-6)
        XCTAssertEqual(smaller.minX + smaller.width * Self.inset, rect.minX + rect.width * Self.inset, accuracy: 0.01)
        XCTAssertEqual(smaller.maxY, rect.maxY, accuracy: 0.01)
        try VitreusFixture.drag(widget, key: "grip", by: CGVector(dx: -150 * du, dy: 100 * du))
        let far = try VitreusFixture.frame(widget, key: "desk")
        Self.assertRect(far, smaller.offsetBy(dx: -150 * du, dy: 100 * du))
        let right = far.maxX - far.width * Self.inset
        try VitreusFixture.drag(
            widget, key: "grip", by: CGVector(dx: corner.x - 30 * du - right, dy: home.minY + 20 * du - far.minY)
        )
        Self.assertRect(try VitreusFixture.frame(widget, key: "desk"), home)
    }

    func testAHeldGripStaysLitWhenTheHoverPointerLeavesItAndDataRerenders() throws {
        let widget = try VitreusFixture.desk(shell())
        let surface = widget.surface
        let grip = try VitreusFixture.frame(widget, key: "grip")
        let start = CGPoint(x: grip.midX, y: grip.midY)
        func opacity() throws -> (paint: Float, layer: Float) {
            let handle = try VitreusFixture.element(widget, key: "grip")
            let scene = surface.scene
            let layer = try ShellLayerScene.engineQueue.sync { try XCTUnwrap(scene.layers[handle.slot]).opacity }
            return (surface.layout.core.paint(of: handle).opacity, layer)
        }
        XCTAssertEqual(try opacity().layer, Float(0.2 / 0.55), accuracy: 0.001)
        surface.hover(at: start)
        XCTAssertEqual(try opacity().layer, 1, accuracy: 0.001)
        VitreusFixture.grab(widget, at: start, to: CGPoint(x: start.x - 2, y: start.y + 2))
        XCTAssertNotNil(surface.manipulation)
        let far = CGPoint(x: start.x - 300, y: start.y + 160)
        surface.drag(to: far, screen: .zero, timestamp: 0.015)
        let pointer = try XCTUnwrap(surface.pointer)
        XCTAssertFalse(CGRect(try surface.presentedFrame(of: VitreusFixture.element(widget, key: "grip")))
            .contains(pointer))
        VitreusFixture.show(widget)
        XCTAssertNotNil(surface.manipulation)
        XCTAssertEqual(try opacity().paint, 1, accuracy: 0.001)
        XCTAssertEqual(try opacity().layer, 1, accuracy: 0.001)
        VitreusFixture.drop(widget, at: far)
        XCTAssertNil(surface.manipulation)
        XCTAssertEqual(try opacity().paint, Float(0.2 / 0.55), accuracy: 0.001)
    }

    func testAGripClickNearHomeResetsAScaledDeskAndClosingForgetsThePlacement() throws {
        let widget = try VitreusFixture.desk(shell())
        let (home, du) = Self.envelope(width: 1920, height: 1080)
        try VitreusFixture.drag(widget, key: "resize-sw", by: CGVector(dx: 120 * du, dy: -120 * du))
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "desk").width / home.width, 0.7, accuracy: 1e-6)
        let placed = try commit(widget)
        try VitreusFixture.click(widget, key: "grip")
        Self.assertRect(try VitreusFixture.frame(widget, key: "desk"), home)
        XCTAssertEqual(try commit(widget), "snap-1")
        XCTAssertNotEqual(placed, "snap-1")
        try VitreusFixture.click(widget, key: "grip")
        XCTAssertEqual(try commit(widget), "snap-1")
        try VitreusFixture.drag(widget, key: "grip", by: CGVector(dx: -200 * du, dy: 0))
        try VitreusFixture.click(widget, key: "grip")
        Self.assertRect(try VitreusFixture.frame(widget, key: "desk"), home.offsetBy(dx: -200 * du, dy: 0))
        try VitreusFixture.drag(widget, key: "resize-nw", by: CGVector(dx: 100 * du, dy: 100 * du))
        XCTAssertLessThan(try VitreusFixture.frame(widget, key: "desk").width, home.width)
        VitreusFixture.trigger(widget.instance, "desk-close", nil)
        VitreusFixture.show(widget)
        let layout = widget.surface.layout
        XCTAssertFalse(layout.core.elements { _ in
            true
        }.contains { layout.core.key(of: $0) == VitreusFixture.key("desk") })
        VitreusFixture.trigger(widget.instance, "desk-open", VitreusFixture.bar().monitorId)
        VitreusFixture.show(widget)
        Self.assertRect(try VitreusFixture.frame(widget, key: "desk"), home)
        let stores = VitreusFixture.drain(widget).filter { $0.kind == OMNI_SERVICE_STORE }
        let placement: Set<String> = ["place", "dx", "dy", "s", "commit", "snaps"]
        for store in stores {
            let keys = Set(store.stored?.fields.map { Array($0.keys) } ?? [])
            XCTAssertTrue(keys.isDisjoint(with: placement), store.name)
        }
    }

    func testRevealMorphsFollowTheVitreusDripFormulas() throws {
        let widget = try VitreusFixture.desk(shell())
        let surface = widget.surface
        let layout = surface.layout
        let reveal = try XCTUnwrap(surface
            .reveal(layout.core.paint(of: VitreusFixture.element(widget, key: "desk")).reveal))
        XCTAssertEqual(reveal.response, 0.482, accuracy: 1e-4)
        XCTAssertEqual(reveal.bounce, 0.31, accuracy: 1e-4)
        let shape = try XCTUnwrap(surface.morph(
            layout.core.paint(of: VitreusFixture.element(widget, key: "desk-shape")).morph
        ))
        XCTAssertEqual(shape.anchor, CGPoint(x: 1, y: 0.5))
        for (value, target) in [
            (shape.stretch.gain, 0.07), (shape.stretch.max, 0.5), (shape.stretch.width, 1), (shape.stretch.height, -0.5)
        ] {
            XCTAssertEqual(value, target, accuracy: 1e-6)
        }
        let times = [0, 0.0625, 0.125, 0.25, 0.375, 0.5, 0.625, 0.6875, 0.75, 0.875, 1, 1.25]
        XCTAssertEqual(shape.stops.count, times.count)
        for (stop, at) in zip(shape.stops, times) {
            XCTAssertEqual(stop.at, at, accuracy: 1e-6)
            XCTAssertEqual(stop.scale, Self.lift(at), accuracy: 1e-6, "\(at)")
            XCTAssertEqual(stop.width, 1 - 0.07 * Self.bell(at), accuracy: 1e-6, "\(at)")
            XCTAssertEqual(stop.height, 1)
            XCTAssertEqual(stop.round, min(max(1.6 * at - 0.1, 0), 1), accuracy: 1e-6, "\(at)")
        }
        let content = try XCTUnwrap(surface.morph(
            layout.core.paint(of: VitreusFixture.element(widget, key: "desk-clip")).morph
        ))
        XCTAssertEqual(content.anchor, CGPoint(x: 1, y: 0.5))
        let table = [
            CGPoint(x: 0, y: 0.05), CGPoint(x: 0.02, y: 0.05), CGPoint(x: 0.0201, y: 0.05), CGPoint(
                x: 0.03125,
                y: 0.05
            ),
            CGPoint(x: 0.625, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 1.25, y: 1.15)
        ]
        XCTAssertEqual(content.stops.count, table.count)
        for (stop, row) in zip(content.stops, table) {
            XCTAssertEqual(stop.at, row.x, accuracy: 1e-6)
            XCTAssertEqual(stop.scale, row.y, accuracy: 1e-6)
            XCTAssertEqual(stop.opacity, row.x <= 0.02 ? 0 : 1)
        }
    }

    func testOnlyTheTabBandRisesFromTheDeskWhileGripAndCloseRideTheContentGroup() throws {
        let widget = try VitreusFixture.desk(shell())
        let surface = widget.surface
        let layout = surface.layout
        let du = 1.242
        let band = try VitreusFixture.element(widget, key: "desk-frame")
        let rise = try presence(widget, layout.core.paint(of: band).appear)
        XCTAssertEqual(rise.delay, 0.2, accuracy: 1e-6)
        XCTAssertEqual(rise.opacity, 0)
        XCTAssertEqual(rise.offset.y, 12 * du, accuracy: 0.001)
        Self.assertSpring(rise.motion, 0.36, 0)
        let fall = try presence(widget, layout.core.paint(of: band).exit)
        XCTAssertEqual(fall.offset.y, 12 * du, accuracy: 0.001)
        XCTAssertEqual(fall.delay, 0)
        Self.assertSpring(fall.motion, 0.076, 0)
        let page = try VitreusFixture.element(widget, key: "page")
        XCTAssertEqual(layout.core.paint(of: page).appear, 0)
        XCTAssertEqual(layout.core.paint(of: page).exit, 0)
        XCTAssertEqual(try layout.core.paint(of: VitreusFixture.element(widget, key: "desk-glass")).appear, 0)
        let root = try presence(widget, layout.core.paint(of: VitreusFixture.element(widget, key: "desk")).exit)
        XCTAssertEqual(root.opacity, 1)
        XCTAssertEqual(root.scale, 1)
        XCTAssertEqual(root.offset.x, 0, accuracy: 1e-6)
        XCTAssertEqual(root.offset.y, 0, accuracy: 1e-6)
        let clip = try VitreusFixture.element(widget, key: "desk-clip")
        for name in ["grip", "close", "resize-nw", "resize-se"] {
            let handle = try VitreusFixture.element(widget, key: name)
            XCTAssertFalse(surface.isWithin(handle, band), name)
            XCTAssertTrue(surface.isWithin(handle, clip), name)
        }
    }

    func testOpenerCrossFadesOnTheDripSpringAndLightsOnlyOnTheDisplayWithTheDesk() throws {
        let shell = try shell()
        let widget = try ShellRenderedWidget(
            source: VitreusFixture.source(shell), resources: VitreusFixture.resources(shell)
        )
        let monitors = [
            VitreusFixture.monitor(VitreusFixture.primary, id: 95111),
            VitreusFixture.monitor(VitreusFixture.secondary, id: 95112)
        ]
        func plate(on monitor: Monitor) throws -> (role: UInt16, alpha: Double) {
            widget.render(VitreusFixture.bar(monitor))
            let layout = widget.surface.layout
            let opener = try VitreusFixture.element(widget, key: "desk-opener")
            let boxes = layout.core.elements { _ in true }.filter { layout.core.parent(of: $0) == opener }
            XCTAssertEqual(boxes.count, 4)
            for box in boxes {
                Self.assertSpring(widget.surface.animation(for: box)?.motion, 0.482, 0.31)
            }
            let plate = try XCTUnwrap(boxes
                .max { layout.core.absoluteFrame(of: $0).width < layout.core.absoluteFrame(of: $1).width })
            let fill = layout.core.paint(of: plate).fill
            return (fill.role & 0xFF, Double(fill.role >> 8) / 255)
        }
        let accent = UInt16(ShellRole.accent.rawValue + 1)
        let ink = UInt16(ShellRole.foreground.rawValue + 1)
        let (first, second) = (VitreusFixture.bar(monitors[0]).monitorId, VitreusFixture.bar(monitors[1]).monitorId)
        XCTAssertEqual(try plate(on: monitors[0]).role, ink)
        VitreusFixture.trigger(widget.instance, "desk-open", first)
        let lit = try plate(on: monitors[0])
        XCTAssertEqual(lit.role, accent)
        XCTAssertEqual(lit.alpha, 0.19, accuracy: 0.003)
        VitreusFixture.trigger(widget.instance, "desk-open", second)
        let dark = try plate(on: monitors[0])
        XCTAssertEqual(dark.role, ink)
        XCTAssertEqual(dark.alpha, 0.07, accuracy: 0.003)
    }

    func testGripDragShowsTheClosedHandAndReleaseRestoresTheHoveredCursor() throws {
        let previous = NSCursor.current
        defer { previous.set() }
        let widget = try VitreusFixture.desk(shell())
        let surface = widget.surface
        let grip = try VitreusFixture.frame(widget, key: "grip")
        let start = CGPoint(x: grip.midX, y: grip.midY)
        surface.hover(at: start)
        XCTAssertTrue(surface.view.cursorState.current === NSCursor.openHand)
        let end = CGPoint(x: start.x - 300, y: start.y + 120)
        VitreusFixture.grab(widget, at: start, to: end)
        XCTAssertNotNil(surface.manipulation)
        XCTAssertTrue(surface.view.cursorState.current === NSCursor.closedHand)
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)
        let tab = try VitreusFixture.frame(widget, key: "tab-focus")
        surface.hover(at: CGPoint(x: tab.midX, y: tab.midY))
        XCTAssertTrue(surface.view.cursorState.current === NSCursor.closedHand)
        let release = CGPoint(x: end.x + 3, y: end.y - 2)
        VitreusFixture.drop(widget, at: release)
        XCTAssertNil(surface.manipulation)
        XCTAssertEqual(surface.pointer, release)
        XCTAssertTrue(surface.view.cursorState.current === NSCursor.openHand)
        XCTAssertTrue(NSCursor.current === NSCursor.openHand)
        let close = try VitreusFixture.frame(widget, key: "close")
        surface.hover(at: CGPoint(x: close.midX, y: close.midY))
        XCTAssertTrue(surface.view.cursorState.current === NSCursor.pointingHand)
        let corner = try VitreusFixture.frame(widget, key: "resize-se")
        let point = CGPoint(x: corner.midX, y: corner.midY)
        VitreusFixture.grab(widget, at: point, to: CGPoint(x: point.x - 40, y: point.y - 40))
        XCTAssertTrue(surface.view.cursorState.current === NSCursor.closedHand)
        surface.cancelManipulation(reason: "test")
        XCTAssertFalse(surface.view.cursorState.manipulating)
        XCTAssertFalse(surface.view.cursorState.current === NSCursor.closedHand)
    }
}
