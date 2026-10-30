// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
extension ShellVitreusDrawerTests {
    static func island(_ widget: ShellRenderedWidget, on monitor: Monitor) -> ShellIsland {
        let island = ShellIsland(
            surface: widget.surface, monitor: monitor, size: monitor.frame.size,
            registry: OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        )
        island.panel.alphaValue = 0
        island.panel.ignoresMouseEvents = true
        island.update(monitor: monitor, size: monitor.frame.size, visible: true, level: .normal)
        return island
    }

    @discardableResult
    static func press(
        _ island: ShellIsland, _ widget: ShellRenderedWidget, at point: CGPoint, button: ShellEvent.Button = .left
    ) -> [Bool?] {
        let index = widget.events.count
        var event = ShellEvent(button: button)
        event.kind = .outsidePress
        let frame = island.geometry.frame
        island.outsidePress(at: CGPoint(x: frame.minX + point.x, y: frame.maxY - point.y), event: event)
        let presses = widget.events.dropFirst(index).filter { $0.event.kind == .outsidePress }
        for press in presses {
            widget.invoke(press.action, event: press.event)
        }
        return presses.map(\.event.claimed)
    }

    static func samples(_ rect: CGRect) -> [CGPoint] {
        [0.02, 0.25, 0.5, 0.75, 0.98].flatMap { x in
            [0.05, 0.5, 0.95].map { y in CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y) }
        }
    }

    func testEveryPressOnThePillOrTheStripIsClaimedSoTheDrawerNeedsNoGeometricExclusion() throws {
        for (layout, area) in [("island", "shell"), ("ftop", "bar-hover")] {
            let fixture = try fixture()
            VitreusFixture.settings(fixture.widget, ["layout": .string(layout)])
            trigger(fixture, "drawer-calendar")
            let island = Self.island(fixture.widget, on: fixture.monitor)
            defer { island.close() }
            for point in Self.samples(try VitreusFixture.frame(fixture.widget, key: area)) {
                XCTAssertEqual(Self.press(island, fixture.widget, at: point), [true], "\(layout) \(point)")
                show(fixture)
            }
            XCTAssertTrue(has(fixture, "drawer-content-calendar"), layout)
            XCTAssertEqual(Self.press(island, fixture.widget, at: CGPoint(x: 960, y: 900)), [false], layout)
            show(fixture)
            XCTAssertFalse(has(fixture, "drawer-content-calendar"), layout)
        }
    }

    func testSwitchingBetweenStripOrPieceButtonsStillQueuesTheNextDrawer() throws {
        for layout in ["ftop", "seg"] {
            let fixture = try fixture()
            VitreusFixture.settings(fixture.widget, ["layout": .string(layout)])
            fixture.widget.set("clock") { $0.string("6:42 pm") }
            fixture.widget.set("date") { $0.string("Tue 28") }
            trigger(fixture, "drawer-controls")
            advance(fixture, by: 2)
            let island = Self.island(fixture.widget, on: fixture.monitor)
            defer { island.close() }
            let clock = try VitreusFixture.frame(fixture.widget, key: "bar-clock")
            XCTAssertEqual(Self.press(island, fixture.widget, at: CGPoint(x: clock.midX, y: clock.midY)), [true])
            show(fixture)
            XCTAssertTrue(has(fixture, "drawer-frame-controls"), layout)
            trigger(fixture, "drawer-calendar")
            let paint = fixture.widget.surface.layout.core.paint(of: try handle(fixture, "drawer-frame-calendar"))
            let reveal = try XCTUnwrap(ShellRevealRecipe(fixture.widget.text.string(paint.reveal)), layout)
            XCTAssertGreaterThan(reveal.delay, 0, layout)
        }
    }
}
