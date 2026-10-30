// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

@MainActor
extension ShellVitreusSectionCardTests {
    func moveCard(_ fixture: ShellVitreusDrawerTests.Fixture, id: String, to point: CGPoint) throws {
        let key = id == "player-album" ? "media-card" : "drawer-content-" + id
        let target = try windows.frame(fixture, key)
        let grip = try windows.frame(fixture, "window-grip-" + id)
        let handle = try VitreusFixture.element(fixture.widget, key: key)
        let parent = fixture.widget.surface.layout.core.parent(of: handle)
        let start = CGPoint(x: grip.midX, y: grip.midY)
        let end = CGPoint(x: start.x + point.x - target.minX, y: start.y + point.y - target.minY)
        let index = fixture.widget.events.count
        fixture.widget.surface.press(at: start, timestamp: 0)
        fixture.widget.surface.drag(to: end, screen: .zero, timestamp: 0.01)
        windows.deliver(fixture, from: index)
        XCTAssertEqual(fixture.widget.surface.manipulation?.target, handle, id)
        XCTAssertEqual(fixture.widget.surface.layout.core.parent(of: handle), parent, id)
        let wire = fixture.widget.output()
        fixture.widget.surface.drag(to: end, screen: .zero, timestamp: 0.015)
        XCTAssertEqual(fixture.widget.output(), wire)
        windows.drop(fixture, at: end)
    }

    func testEverySectionUsesAllFourEdgesAndOnlyItsTwoRestingPieces() throws {
        let sticks = ShellVitreusWindowStickTests()
        for (owner, id) in [
            ("calendar", "calendar-month"), ("calendar", "calendar-events"),
            ("controls", "controls-toggles"), ("controls", "controls-sliders"),
            ("controls", "controls-mixer"), ("player", "player-album"), ("player", "player-windows")
        ] {
            let fixture = try windows.fixture()
            windows.trigger(fixture, "drawer-" + owner)
            if id == "controls-mixer" { try windows.invoke(fixture, "controls-mixer-toggle") }
            let target = id == "player-album" ? "media-card" : "drawer-content-" + id
            let size = try windows.frame(fixture, target).size
            for (side, edge) in sticks.sides {
                try moveCard(fixture, id: id, to: sticks.placement(side, size: size))
                sticks.assertFlush(try windows.frame(fixture, target), side: side)
                let prefix = id + "-card" + (side == "right" ? "" : "-" + side)
                let source = try XCTUnwrap(windows.drawers.morph(fixture, prefix + "-lip").source)
                XCTAssertEqual(source.target, VitreusFixture.key(target))
                XCTAssertEqual(source.edge, edge)
                XCTAssertTrue(source.contact)
                XCTAssertTrue(windows.has(fixture, prefix + "-bulge"))
                XCTAssertFalse(windows.has(fixture, prefix + "-stray"))
                XCTAssertFalse(windows.has(fixture, prefix + "-ripple-break-top"))
                for (other, _) in sticks.sides where other != side {
                    XCTAssertFalse(windows.has(fixture, id + "-card" + (other == "right" ? "" : "-" + other) + "-lip"))
                }
            }
        }
    }

    func testAnAlbumStoredSeparatelyRetractsItsPanelAndCanBePulledOutAgain() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-player")
        let home = try windows.frame(fixture, "media-card")
        let size = try windows.frame(fixture, "drawer-content-player").size
        windows.shelfOpen = true
        windows.show(fixture)
        let shelf = try windows.frame(fixture, "window-shelf")
        try moveCard(fixture, id: "player-album", to: CGPoint(x: shelf.minX + 15 - home.width / 2, y: 10))
        XCTAssertLessThan(try windows.frame(fixture, "drawer-content-player").height, size.height)
        XCTAssertFalse(windows.has(fixture, "card-slot-player-album"))
        windows.shelfOpen = false
        windows.show(fixture)
        XCTAssertFalse(windows.has(fixture, "media-card"))
        XCTAssertTrue(windows.has(fixture, "drawer-content-player"))
        try windows.move(fixture, id: "player", to: CGPoint(x: 1100, y: 550))
        windows.shelfOpen = true
        windows.show(fixture)
        try moveCard(fixture, id: "player-album", to: CGPoint(x: 100, y: 500))
        windows.shelfOpen = false
        windows.show(fixture)
        XCTAssertTrue(windows.has(fixture, "media-card-glass"))
        XCTAssertEqual(try windows.frame(fixture, "media-card").width, home.width, accuracy: 0.01)
        windows.trigger(fixture, "drawer-player")
        ShellVitreusMediaCardTests.assertRect(try windows.frame(fixture, "media-card"), home)
    }

    func testPageExtractionRestoresReadableSizeAndShelfCloseKeepsTheDraft() throws {
        let shell = try VitreusFixture.shell()
        defer { VitreusFixture.remove(shell) }
        let widget = try VitreusFixture.desk(shell)
        let fixture = ShellVitreusDrawerTests.Fixture(
            widget: widget, monitor: VitreusFixture.monitor(width: 1280, height: 800), clock: .init(),
            scene: widget.surface.scene
        )
        windows.shelfOpen = true
        windows.show(fixture)
        let target = try VitreusFixture.element(widget, key: "drawer-content-page-pad")
        let input = try XCTUnwrap(widget.surface.layout.core.elements { $0.action != 0 }.first {
            widget.surface.layout.core.kind(of: $0) == .input && widget.surface.isWithin($0, target)
        })
        var event = ShellEvent()
        event.text = "Do not lose this when the shelf closes"
        widget.invoke(widget.surface.layout.core.content(of: input).action, event: event)
        windows.show(fixture)
        let small = try windows.frame(fixture, "drawer-content-page-pad")
        XCTAssertLessThan(small.width, 340 * 1.5525)
        XCTAssertGreaterThanOrEqual(try windows.frame(fixture, "window-grip-page-pad").height, 10)
        windows.shelfOpen = false
        windows.show(fixture)
        windows.shelfOpen = true
        windows.show(fixture)
        XCTAssertTrue(widget.strings().contains("Do not lose this when the shelf closes"))
        try moveCard(fixture, id: "page-pad", to: CGPoint(x: 50, y: 650))
        XCTAssertEqual(try windows.frame(fixture, "drawer-content-page-pad").width, 340 * 1.5525, accuracy: 0.01)
        XCTAssertEqual(try windows.frame(fixture, "drawer-content-page-pad").height, 360 * 1.5525, accuracy: 0.01)
        XCTAssertEqual(try VitreusFixture.element(widget, key: "drawer-content-page-pad"), target)
        XCTAssertTrue(widget.strings().contains("Do not lose this when the shelf closes"))
    }
}
