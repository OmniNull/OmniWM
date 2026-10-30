// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
extension ShellVitreusMediaCardTests {
    func testThePinLeavesAnOpenPlayerDrawerOpen() throws {
        let fixture = try fixture()
        try float(fixture, by: CGVector(dx: 300, dy: 400))
        XCTAssertTrue(has(fixture, "drawer-content-player"))
        let pin = try frame(fixture, "media-card-pin")
        let index = fixture.widget.events.count
        fixture.widget.surface.press(at: CGPoint(x: pin.midX, y: pin.midY))
        fixture.widget.surface.release(at: CGPoint(x: pin.midX, y: pin.midY))
        XCTAssertEqual(deliver(fixture, from: index), [])
        XCTAssertTrue(has(fixture, "drawer-content-player"))
        Self.assertRect(try frame(fixture, "media-card"), try docked(fixture))
        XCTAssertEqual(try commit(fixture), "pin-1")
    }

    func testTheDockedCardScalesAndDropsWithThePlayerDrawerContent() throws {
        for edge in ["island", "left", "right", "ftop", "fbottom", "seg"] {
            let fixture = try fixture()
            VitreusFixture.settings(
                fixture.widget,
                ["pieces": .strings(["workspaces", "title"]), "layout": .string(edge)]
            )
            show(fixture)
            let surface = fixture.widget.surface
            let plate = try frame(fixture, "player-media")
            func placed(_ key: String, at progress: Double) throws -> [CGFloat] {
                let morph = try XCTUnwrap(
                    surface.morph(surface.layout.core.paint(of: element(fixture, key)).morph),
                    key
                )
                let frame = try frame(fixture, key)
                let stop = morph.stop(at: progress)
                let pivot = CGPoint(
                    x: frame.minX + frame.width * morph.anchor.x, y: frame.minY + frame.height * morph.anchor.y
                )
                return [plate.minX, plate.maxX].map { pivot.x + stop.dx + ($0 - pivot.x) * stop.scale }
                    + [plate.minY, plate.maxY].map { pivot.y + stop.dy + ($0 - pivot.y) * stop.scale }
            }
            let progress = edge == "island" ? [0.0625, 0.3, 0.625, 0.8, 1, 1.2, 1.5]
                : [0.0201, 0.03125, 0.0625, 0.3, 0.625, 0.8, 1, 1.2, 1.5]
            for progress in progress {
                let card = try placed("media-card-dock", at: progress)
                let drawer = try placed("drawer-clip", at: progress)
                for (value, target) in zip(card, drawer) {
                    XCTAssertEqual(value, target, accuracy: 0.01, "progress \(progress)")
                }
            }
        }
    }

    func testEveryLayoutDeliversThePlateOnceThroughTheSingleCardTarget() throws {
        let fixture = try fixture()
        func plate(within owner: String) throws -> Bool {
            let layout = fixture.widget.surface.layout
            let plates = layout.core.elements { _ in true }
                .filter { layout.core.key(of: $0) == VitreusFixture.key("player-media") }
            XCTAssertEqual(plates.count, 1, owner)
            return try fixture.widget.surface.isWithin(XCTUnwrap(plates.first, owner), element(fixture, owner))
        }
        XCTAssertTrue(try plate(within: "media-card"))
        VitreusFixture.settings(
            fixture.widget, ["pieces": .strings(["workspaces", "title"]), "layout": .string("ftop")]
        )
        show(fixture)
        XCTAssertTrue(has(fixture, "media-card"))
        XCTAssertTrue(try plate(within: "media-card"))
        XCTAssertFalse(try plate(within: "drawer-content-player"))
    }

    func testPressingTheCardItsPinOrTheDeskKeepsThePlayerDrawerSoADropCanDockTheCard() throws {
        let fixture = try fixture(desk: true)
        try float(fixture, by: CGVector(dx: -500, dy: 400))
        let island = ShellVitreusDrawerTests.island(fixture.widget, on: VitreusFixture.monitor())
        defer { island.close() }
        func press(_ point: CGPoint) -> [Bool?] {
            let claimed = ShellVitreusDrawerTests.press(island, fixture.widget, at: point)
            show(fixture)
            return claimed
        }
        let pin = try frame(fixture, "media-card-pin"), grip = try frame(fixture, "grip")
        for point in [try cover(fixture), CGPoint(x: pin.midX, y: pin.midY), CGPoint(x: grip.midX, y: grip.midY)] {
            XCTAssertEqual(press(point), [true], "\(point)")
            XCTAssertTrue(has(fixture, "drawer-content-player"), "\(point)")
        }
        let start = try cover(fixture)
        let slot = try docked(fixture)
        let current = try frame(fixture, "media-card")
        drag(fixture, at: start, by: CGVector(dx: slot.minX + 5 - current.minX, dy: slot.minY + 5 - current.minY))
        XCTAssertFalse(has(fixture, "media-card-glass"))
        Self.assertRect(try frame(fixture, "media-card"), try docked(fixture))
        XCTAssertEqual(press(CGPoint(x: 960, y: 900)), [false])
        XCTAssertFalse(has(fixture, "drawer-content-player"))
        VitreusFixture.trigger(fixture.widget.instance, "drawer-player", fixture.bar.monitorId)
        show(fixture)
        XCTAssertEqual(press(CGPoint(x: -300, y: 500)), [false])
        XCTAssertFalse(has(fixture, "drawer-content-player"))
    }

    func testTheDockedGrabCoversOnlyThePlateSoThePillAndTheFirstRowKeepTheirPresses() throws {
        var fixture = try fixture()
        var bar = fixture.bar
        bar.workspaces = [ShellBarWorkspace(id: "1", name: "1", focused: true, windows: [ShellBarItem(
            id: "app", bundle: "test.app", name: "App", focused: true, count: 1, hidden: 0,
            windows: [.init(id: "window-1", title: "Window 1", focused: true, hidden: false)]
        )])]
        fixture = Fixture(widget: fixture.widget, bar: bar)
        show(fixture)
        let surface = fixture.widget.surface
        let card = try frame(fixture, "media-card"), pill = try frame(fixture, "shell")
        let row = try frame(fixture, "player-task-window-1")
        Self.assertRect(try frame(fixture, "media-card-grab"), card.insetBy(dx: 10 * Self.cu, dy: 10 * Self.cu))
        Self.assertRect(try frame(fixture, "player-media"), try frame(fixture, "media-card-grab"))
        XCTAssertGreaterThan(card.minY, pill.maxY)
        XCTAssertGreaterThan(card.maxY, row.minY)
        let above = CGPoint(x: card.midX, y: pill.midY)
        let below = CGPoint(x: card.midX, y: (row.minY + card.maxY) / 2)
        for (point, key) in [(above, "bar-hover"), (below, "player-task-window-1")] {
            let hit = surface.element(at: point) { $0.acceptsPointer }
            XCTAssertTrue(surface.isWithin(hit, try element(fixture, key)), key)
        }
        try float(fixture, by: CGVector(dx: 300, dy: 400))
        let floating = try frame(fixture, "media-card")
        let corner = try element(fixture, "media-card-resize-nw")
        Self.assertRect(try frame(fixture, "media-card-resize-nw"), CGRect(
            origin: floating.origin, size: CGSize(width: 28 * Self.cu, height: 28 * Self.cu)
        ))
        XCTAssertFalse(surface.isWithin(corner, try element(fixture, "media-card-grab")))
        XCTAssertEqual(try recipe(fixture, "media-card-resize-nw").target, VitreusFixture.key("media-card"))
    }

    func testTheDockedCardRisesAfterItsDelayAndTheFloatingCardStaysInsideTheMonitor() throws {
        let fixture = try fixture()
        func rise() throws -> ShellPresenceRecipe {
            try XCTUnwrap(ShellPresenceRecipe(fixture.widget.text.string(paint(fixture, "media-card-rise").appear)))
        }
        XCTAssertEqual(try rise().delay, 0.2, accuracy: 1e-6)
        XCTAssertEqual(try rise().offset.y, 12 * Self.cu, accuracy: 1e-3)
        XCTAssertEqual(try rise().opacity, 0)
        guard case let .spring(response, bounce)? = try rise().motion else { return XCTFail("the card rises on f3") }
        XCTAssertEqual(response, 2 * .pi * 0.52 / 6.64, accuracy: 1e-4)
        XCTAssertEqual(bounce, 0, accuracy: 1e-6)
        try float(fixture, by: CGVector(dx: 300, dy: 400))
        XCTAssertEqual(try rise().delay, 0)
        let bounds = try recipe(fixture, "media-card-grab").bounds
        try drag(fixture, key: "media-card-grab", by: CGVector(dx: 5000, dy: 5000))
        fixture.widget.surface.finishSettle()
        XCTAssertEqual(try frame(fixture, "media-card").maxX, 1920, accuracy: 0.01)
        XCTAssertEqual(try frame(fixture, "media-card").maxY, 1080, accuracy: 0.01)
        let small = VitreusFixture.monitor(width: 1440, height: 900)
        fixture.widget.set("island") { VitreusFixture.island(small).write(to: &$0) }
        fixture.widget.render(fixture.bar)
        let desk = try recipe(fixture, "media-card-grab").bounds
        XCTAssertLessThan(desk.maxX, bounds.maxX)
        XCTAssertEqual(try frame(fixture, "media-card").maxX, 1440, accuracy: 0.01)
        XCTAssertEqual(try frame(fixture, "media-card").maxY, 900, accuracy: 0.01)
    }

    func testTheGripBrightensOnlyWhileTheFloatingGrabIsHoveredOrHeld() throws {
        let fixture = try fixture()
        try float(fixture, by: CGVector(dx: 300, dy: 400))
        func grip() throws -> Float {
            try paint(fixture, "media-card-grip").opacity
        }
        func hover(_ point: CGPoint?) {
            let index = fixture.widget.events.count
            fixture.widget.surface.hover(at: point)
            deliver(fixture, from: index)
        }
        let plate = try frame(fixture, "media-card-grab")
        let away = CGPoint(x: plate.minX - 120, y: plate.midY)
        hover(away)
        XCTAssertEqual(try grip(), 0.2, accuracy: 1e-6)
        hover(CGPoint(x: plate.midX, y: plate.midY))
        XCTAssertEqual(try grip(), 0.55, accuracy: 1e-6)
        hover(away)
        XCTAssertEqual(try grip(), 0.2, accuracy: 1e-6)
        let held = grab(fixture, at: try cover(fixture), by: CGVector(dx: 40, dy: 0))
        XCTAssertEqual(try grip(), 0.55, accuracy: 1e-6)
        drop(fixture, at: held)
    }
}
