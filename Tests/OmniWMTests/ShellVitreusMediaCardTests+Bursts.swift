// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import QuartzCore
import XCTest

@MainActor
extension ShellVitreusMediaCardTests {
    func testTrackChangesWithinASecondOverlapUpToTwoBurstsEachOnItsOwnTimer() throws {
        let art = "/nonexistent/cover.png"
        let fixture = try fixture(artwork: art)
        XCTAssertEqual(timers(fixture).count, 0)
        play(fixture, "Second song", artwork: art)
        show(fixture)
        let first = try XCTUnwrap(timers(fixture).first)
        let opening = try pulse(fixture).key
        play(fixture, "Third song", artwork: art)
        show(fixture)
        let second = timers(fixture)
        XCTAssertEqual(second.map(\.seconds), [1.1])
        XCTAssertTrue(has(fixture, "media-card-sparks-1"))
        XCTAssertTrue(has(fixture, "media-card-sparks-2"))
        XCTAssertNotEqual(try pulse(fixture).key, opening)
        play(fixture, "Fourth song", artwork: art)
        show(fixture)
        let third = timers(fixture)
        XCTAssertEqual(third.map(\.seconds), [0, 1.1])
        XCTAssertEqual(third.first?.id, first.id)
        XCTAssertFalse(has(fixture, "media-card-sparks-1"))
        XCTAssertTrue(has(fixture, "media-card-sparks-2"))
        XCTAssertTrue(has(fixture, "media-card-sparks-3"))
        let newest = try pulse(fixture).key
        VitreusFixture.complete(fixture.widget, try XCTUnwrap(second.first))
        show(fixture)
        XCTAssertFalse(has(fixture, "media-card-sparks-2"))
        XCTAssertTrue(has(fixture, "media-card-sparks-3"))
        XCTAssertEqual(try pulse(fixture).key, newest)
        VitreusFixture.complete(fixture.widget, try XCTUnwrap(third.last))
        show(fixture)
        XCTAssertFalse(has(fixture, "media-card-sparks"))
        XCTAssertEqual(try paint(fixture, "player-media-cover").pulse, 0)
    }

    func testATrackChangeWhileTheCardIsHiddenNeitherPulsesNorBurstsWhenItReturns() throws {
        let art = "/nonexistent/cover.png"
        let fixture = try fixture(artwork: art)
        VitreusFixture.trigger(fixture.widget.instance, "drawer-close", fixture.bar.monitorId)
        show(fixture)
        XCTAssertFalse(has(fixture, "media-card"))
        play(fixture, "Second song", artwork: art)
        show(fixture)
        XCTAssertEqual(timers(fixture).count, 0)
        VitreusFixture.trigger(fixture.widget.instance, "drawer-player", fixture.bar.monitorId)
        show(fixture)
        XCTAssertTrue(has(fixture, "media-card"))
        XCTAssertEqual(try paint(fixture, "player-media-cover").pulse, 0)
        XCTAssertFalse(has(fixture, "media-card-sparks"))
    }

    func testDockedSparksAreMaskedToTheDrawerShapeWhileFloatingSparksAreNot() throws {
        let fixture = try fixture()
        play(fixture, "Second song")
        show(fixture)
        let surface = fixture.widget.surface
        let clip = try element(fixture, "media-card-sparks-clip")
        let host = try element(fixture, "media-card-sparks")
        XCTAssertTrue(surface.layout.core.paint(of: clip).masks)
        XCTAssertEqual(surface.layout.core.parent(of: clip), host)
        XCTAssertEqual(surface.layout.core.parent(of: try element(fixture, "media-card-sparks-1")), host)
        let drawer = try frame(fixture, "drawer")
        Self.assertRect(try frame(fixture, "media-card-sparks-clip"), drawer)
        let scene = surface.scene
        let outline = try ShellLayerScene.engineQueue.sync { () -> CGRect in
            let mask = try XCTUnwrap(scene.masks[clip.slot])
            XCTAssertTrue(mask.host.mask === mask.layer)
            return try XCTUnwrap((mask.layer as? CAShapeLayer)?.path).boundingBox
        }
        Self.assertRect(outline, CGRect(x: 2, y: 2, width: drawer.width - 4, height: drawer.height - 4))
        try float(fixture, by: CGVector(dx: 300, dy: 400))
        play(fixture, "Third song")
        show(fixture)
        XCTAssertTrue(has(fixture, "media-card-sparks-2"))
        XCTAssertFalse(has(fixture, "media-card-sparks-clip"))
    }
}
