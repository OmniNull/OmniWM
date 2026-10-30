// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
extension ShellVitreusMediaCardTests {
    func testFrameCardsUseOneTargetAndBodyWithIndependentEdgeAdhesionAndRoomBounds() throws {
        for edge in ["left", "right", "ftop", "fbottom", "seg"] {
            let fixture = try fixture()
            VitreusFixture.settings(
                fixture.widget,
                ["pieces": .strings(["workspaces", "title"]), "layout": .string(edge)]
            )
            show(fixture)
            XCTAssertTrue(has(fixture, "media-card"), edge)
            XCTAssertFalse(has(fixture, "media-card-glass"), edge)
            try float(fixture, by: CGVector(dx: edge == "right" ? -300 : 300, dy: edge == "fbottom" ? -300 : 300))
            let layout = fixture.widget.surface.layout
            let glass = try element(fixture, "media-card-glass")
            XCTAssertEqual(layout.core.parent(of: glass), try element(fixture, "bar"))
            XCTAssertFalse(has(fixture, "desk-glass"))
            let raw = fixture.widget.text.string(layout.core.paint(of: glass).morph)
            let source = try XCTUnwrap(ShellMorphRecipe(raw)?.source)
            XCTAssertEqual(layout.core.content(of: glass).glassFollow, 0)
            XCTAssertEqual(source.target, VitreusFixture.key("media-card"))
            XCTAssertEqual(source.edge, .right)
            XCTAssertEqual(source.span, 50 * 1.35, accuracy: 0.001)
            XCTAssertNotNil(source.pads)
            XCTAssertNotNil(source.adhere.left)
            XCTAssertNotNil(source.adhere.top)
            XCTAssertNotNil(source.adhere.bottom)
            let bounds = try recipe(fixture, "media-card-grab").bounds
            XCTAssertEqual(bounds.minX, edge == "left" ? 62.1 : 10.8, accuracy: 0.001)
            XCTAssertEqual(bounds.maxX, 1920 - (edge == "right" ? 62.1 : 10.8), accuracy: 0.001)
            XCTAssertEqual(try frame(fixture, "drawer-content-player").height, 55.5 * Self.cu, accuracy: 0.01)
            XCTAssertEqual(layout.core.elements { _ in true }.count {
                layout.core.key(of: $0) == VitreusFixture.key("player-media")
            }, 1)
            XCTAssertTrue(fixture.widget.surface.isWithin(
                try element(fixture, "player-media"),
                try element(fixture, "media-card")
            ))
            let pin = try frame(fixture, "media-card-pin")
            let start = fixture.widget.events.count
            fixture.widget.surface.press(at: CGPoint(x: pin.midX, y: pin.midY))
            fixture.widget.surface.release(at: CGPoint(x: pin.midX, y: pin.midY))
            _ = deliver(fixture, from: start)
            XCTAssertFalse(has(fixture, "media-card-glass"))
            Self.assertRect(try frame(fixture, "media-card"), try docked(fixture))
            XCTAssertEqual(try frame(fixture, "drawer-content-player").height, (55.5 + 156) * Self.cu, accuracy: 0.01)
        }
    }

    func testSwitchingAFloatingIslandCardThroughFrameLayoutsKeepsExactlyOnePlateAndReturnsToC8() throws {
        let fixture = try fixture()
        try float(fixture, by: CGVector(dx: 300, dy: 400))
        for edge in ["ftop", "left", "right", "fbottom", "seg", "island"] {
            VitreusFixture.settings(
                fixture.widget,
                ["pieces": .strings(["workspaces", "title"]), "layout": .string(edge)]
            )
            show(fixture)
            let layout = fixture.widget.surface.layout
            let glass = try element(fixture, "media-card-glass")
            let body = edge == "island" ? "desk-glass" : "bar"
            XCTAssertEqual(layout.core.parent(of: glass), try element(fixture, body))
            XCTAssertEqual(layout.core.elements { _ in true }.count {
                layout.core.key(of: $0) == VitreusFixture.key("player-media")
            }, 1, edge)
            XCTAssertEqual(
                try frame(fixture, "drawer-content-player").height,
                (55.5 + (edge == "island" ? 14 : 0)) * Self.cu,
                accuracy: 0.01
            )
            if edge == "island" {
                XCTAssertEqual(layout.core.content(of: glass).glassFollow, VitreusFixture.key("media-card"))
                XCTAssertTrue(layout.core.content(of: glass).glassFollowFixedRadius)
                XCTAssertNil(ShellMorphRecipe(fixture.widget.text.string(layout.core.paint(of: glass).morph))?.source)
            }
        }
    }

    func testEmptyDeskPressesAreClaimedWithoutStealingAChildControl() throws {
        let fixture = try fixture(desk: true)
        let band = try element(fixture, "desk-band")
        let bounds = try frame(fixture, "desk-band")
        let surface = fixture.widget.surface
        var points: [CGPoint] = []
        for y in 1 ..< 10 {
            for x in 1 ..< 10 {
                points.append(CGPoint(
                    x: bounds.minX + bounds.width * CGFloat(x) / 10,
                    y: bounds.minY + bounds.height * CGFloat(y) / 10
                ))
            }
        }
        let point = try XCTUnwrap(points.first {
            surface.element(at: $0, matching: { $0.acceptsPointer }) == band
        })
        let island = ShellVitreusDrawerTests.island(fixture.widget, on: VitreusFixture.monitor())
        defer { island.close() }
        XCTAssertEqual(ShellVitreusDrawerTests.press(island, fixture.widget, at: point), [true])
        show(fixture)
        XCTAssertTrue(has(fixture, "drawer-content-player"))
        let grip = try frame(fixture, "grip")
        let hit = surface.element(at: CGPoint(x: grip.midX, y: grip.midY), matching: { $0.acceptsPointer })
        XCTAssertNotEqual(hit, band)
        XCTAssertTrue(surface.isWithin(hit, try element(fixture, "grip")))
    }

    func testFrameDockedSparksUseTheFrameDrawerOutline() throws {
        let fixture = try fixture()
        VitreusFixture.settings(
            fixture.widget,
            ["pieces": .strings(["workspaces", "title"]), "layout": .string("left")]
        )
        show(fixture)
        play(fixture, "Second song")
        show(fixture)
        Self.assertRect(try frame(fixture, "media-card-sparks-clip"), try frame(fixture, "drawer-frame-player"))
        XCTAssertTrue(try paint(fixture, "media-card-sparks-clip").masks)
    }
}
