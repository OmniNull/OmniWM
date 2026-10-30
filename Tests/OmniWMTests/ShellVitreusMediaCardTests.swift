// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellVitreusMediaCardTests: XCTestCase {
    static let cu = 1.5525

    struct Fixture {
        let widget: ShellRenderedWidget
        let bar: ShellBarData
    }

    func fixture(scale: CGFloat = 2, artwork: String? = nil, desk: Bool = false) throws -> Fixture {
        let shell = try VitreusFixture.shell()
        addTeardownBlock { VitreusFixture.remove(shell) }
        let widget = try ShellRenderedWidget(
            source: VitreusFixture.source(shell), scale: scale, resources: VitreusFixture.resources(shell)
        )
        VitreusFixture.settings(widget, ["pieces": .strings(["workspaces", "title"])])
        let fixture = Fixture(widget: widget, bar: VitreusFixture.bar())
        play(fixture, "First song", artwork: artwork)
        show(fixture)
        if desk { VitreusFixture.trigger(widget.instance, "desk-open", fixture.bar.monitorId) }
        VitreusFixture.trigger(widget.instance, "drawer-player", fixture.bar.monitorId)
        show(fixture)
        omni_instance_clear_messages(widget.instance)
        return fixture
    }

    func play(
        _ fixture: Fixture,
        _ title: String,
        artwork: String? = nil,
        playing: Bool = true,
        duration: Double? = 240
    ) {
        var media = ShellMedia()
        media.title = title
        media.artist = "An artist"
        media.bundle = "test.music"
        media.app = "Music"
        media.playing = playing
        media.elapsed = 30
        media.duration = duration
        media.rate = playing ? 1 : 0
        media.sampledAt = 95
        media.artwork = artwork
        fixture.widget.set("media") { media.write(into: &$0) }
    }

    func show(_ fixture: Fixture, acknowledgement: UInt64 = 0) {
        fixture.widget.set("seconds") { $0.number(100) }
        fixture.widget.set("island") { VitreusFixture.island(VitreusFixture.monitor()).write(to: &$0) }
        fixture.widget.render(fixture.bar, acknowledgement: acknowledgement)
        fixture.widget.surface.view.frame = CGRect(origin: .zero, size: fixture.widget.surface.size)
    }

    func element(_ fixture: Fixture, _ key: String) throws -> ElementHandle {
        try VitreusFixture.element(fixture.widget, key: key)
    }

    func frame(_ fixture: Fixture, _ key: String) throws -> CGRect {
        try VitreusFixture.frame(fixture.widget, key: key)
    }

    func has(_ fixture: Fixture, _ key: String) -> Bool {
        ShellVitreusBarTests.has(fixture.widget, key)
    }

    func content(_ fixture: Fixture, _ key: String) throws -> Content {
        try fixture.widget.surface.layout.core.content(of: element(fixture, key))
    }

    func paint(_ fixture: Fixture, _ key: String) throws -> Paint {
        try fixture.widget.surface.layout.core.paint(of: element(fixture, key))
    }

    func commit(_ fixture: Fixture) throws -> String {
        try fixture.widget.text.string(content(fixture, "media-card").manipulationCommit)
    }

    func recipe(_ fixture: Fixture, _ key: String) throws -> ShellManipulationRecipe {
        try XCTUnwrap(ShellManipulationRecipe(fixture.widget.text.string(content(fixture, key).gestureTrack)), key)
    }

    func children(_ fixture: Fixture, of key: String) throws -> [ElementHandle] {
        let layout = fixture.widget.surface.layout
        let parent = try element(fixture, key)
        return layout.core.elements { _ in true }.filter { layout.core.parent(of: $0) == parent }
    }

    @discardableResult
    func deliver(_ fixture: Fixture, from index: Int) -> [String] {
        var requests: [String] = []
        for click in fixture.widget.events.dropFirst(index) where click.action & OMNI_ACTION_HANDLER != 0 {
            requests += fixture.widget.invoke(click.action, event: click.event)
        }
        show(fixture, acknowledgement: fixture.widget.invocation ?? 0)
        return requests
    }

    func grab(_ fixture: Fixture, at start: CGPoint, by offset: CGVector) -> CGPoint {
        let end = CGPoint(x: start.x + offset.dx, y: start.y + offset.dy)
        let index = fixture.widget.events.count
        fixture.widget.surface.press(at: start, timestamp: 0)
        fixture.widget.surface.drag(to: end, screen: .zero, timestamp: 0.01)
        deliver(fixture, from: index)
        return end
    }

    @discardableResult
    func drop(_ fixture: Fixture, at point: CGPoint) -> [String] {
        let index = fixture.widget.events.count
        fixture.widget.surface.release(at: point, timestamp: 0.02)
        return deliver(fixture, from: index)
    }

    func drag(_ fixture: Fixture, at start: CGPoint, by offset: CGVector) {
        drop(fixture, at: grab(fixture, at: start, by: offset))
    }

    func drag(_ fixture: Fixture, key: String, by offset: CGVector) throws {
        let zone = try frame(fixture, key)
        drag(fixture, at: CGPoint(x: zone.midX, y: zone.midY), by: offset)
    }

    func cover(_ fixture: Fixture) throws -> CGPoint {
        let card = try frame(fixture, "media-card")
        return CGPoint(x: card.minX + card.width * 58 / 308, y: card.minY + card.height * 60 / 168)
    }

    func docked(_ fixture: Fixture) throws -> CGRect {
        let drawer = try frame(fixture, "drawer-content-player")
        let inset = has(fixture, "window-grip-player") ? 12.0 : -2.0
        return CGRect(
            x: drawer.minX + 10 * Self.cu, y: drawer.minY + inset * Self.cu, width: 308 * Self.cu, height: 168 * Self.cu
        )
    }

    func float(_ fixture: Fixture, by offset: CGVector) throws {
        drag(fixture, at: try cover(fixture), by: offset)
        XCTAssertTrue(has(fixture, "media-card-glass"))
        fixture.widget.surface.finishSettle()
    }

    static func assertRect(_ actual: CGRect, _ expected: CGRect, line: UInt = #line) {
        for (value, target) in [
            (actual.minX, expected.minX), (actual.minY, expected.minY),
            (actual.width, expected.width), (actual.height, expected.height)
        ] {
            XCTAssertEqual(value, target, accuracy: 0.01, line: line)
        }
    }

    static func assertValues(_ actual: SIMD4<Float>, _ expected: SIMD4<Float>, line: UInt = #line) {
        for index in 0 ..< 4 {
            XCTAssertEqual(actual[index], expected[index], accuracy: 1e-4, "value \(index)", line: line)
        }
    }
}

extension ShellVitreusMediaCardTests {
    func testTheDockedCardFloatsOnlyOncePulledSixteenUnitsOutOfThePlayerDrawer() throws {
        let fixture = try fixture()
        let cu = Self.cu
        let home = try docked(fixture)
        let drawer = try frame(fixture, "drawer-content-player")
        Self.assertRect(try frame(fixture, "media-card"), home)
        Self.assertRect(try frame(fixture, "player-media"), CGRect(
            x: drawer.minX + 20 * cu, y: drawer.minY + 22 * cu, width: 288 * cu, height: 148 * cu
        ))
        let wrapper = try content(fixture, "media-card-grab")
        XCTAssertEqual(wrapper.gesture.axis, .free)
        XCTAssertEqual(Double(wrapper.gesture.threshold), 16 * cu, accuracy: 1e-3)
        let move = try recipe(fixture, "media-card-grab")
        XCTAssertEqual(move.mode, .move)
        XCTAssertEqual(move.target, VitreusFixture.key("media-card"))
        guard case let .spring(response, bounce)? = ShellMotion(
            recipe: fixture.widget.text.string(try content(fixture, "media-card").manipulationFollow)
        ) else { return XCTFail("The card follows on mf_sp") }
        XCTAssertEqual(response, 0.363, accuracy: 1e-4)
        XCTAssertEqual(bounce, 0.42, accuracy: 1e-4)
        let start = try cover(fixture)
        drag(fixture, at: start, by: CGVector(dx: 15.8 * cu, dy: 0))
        XCTAssertFalse(has(fixture, "media-card-glass"))
        Self.assertRect(try frame(fixture, "media-card"), home)
        XCTAssertEqual(try frame(fixture, "drawer-content-player").height, drawer.height, accuracy: 0.01)
        drag(fixture, at: start, by: CGVector(dx: 12 * cu, dy: 12 * cu))
        Self.assertRect(try frame(fixture, "media-card"), home)
        let pull = CGVector(dx: 400, dy: 400)
        drag(fixture, at: start, by: pull)
        Self.assertRect(try frame(fixture, "media-card"), home.offsetBy(dx: pull.dx, dy: pull.dy))
        XCTAssertTrue(try commit(fixture).hasPrefix("placement-"))
        XCTAssertEqual(try frame(fixture, "drawer-content-player").height, drawer.height - 156 * cu, accuracy: 0.01)
        XCTAssertEqual(try content(fixture, "media-card-grab").gesture.threshold, 4)
        XCTAssertEqual(try paint(fixture, "player-media-plate").opacity, 0)
        for key in ["media-card-pin", "media-card-grip", "media-card-resize-nw", "media-card-resize-se"] {
            XCTAssertTrue(has(fixture, key), key)
        }
    }

    func testTheFloatingGlassFollowsTheCardWithAFixedCornerAndDripsInOnItsShapeTrack() throws {
        let fixture = try fixture()
        try float(fixture, by: CGVector(dx: 300, dy: 400))
        let surface = fixture.widget.surface
        let layout = surface.layout
        let glass = try element(fixture, "media-card-glass")
        XCTAssertEqual(try children(fixture, of: "desk-glass").filter { $0 == glass }, [glass])
        Self.assertRect(try frame(fixture, "media-card-glass"), try frame(fixture, "media-card"))
        XCTAssertEqual(layout.core.content(of: glass).glassFollow, VitreusFixture.key("media-card"))
        XCTAssertTrue(layout.core.content(of: glass).glassFollowFixedRadius)
        XCTAssertEqual(surface.followedTarget(of: glass), try element(fixture, "media-card"))
        XCTAssertEqual(Double(layout.core.paint(of: glass).cornerRadius), 26 * Self.cu, accuracy: 1e-3)
        let reveal = try XCTUnwrap(surface.reveal(layout.core.paint(of: glass).reveal))
        XCTAssertEqual(reveal.response, 0.482, accuracy: 1e-4)
        XCTAssertEqual(reveal.bounce, 0.31, accuracy: 1e-4)
        XCTAssertTrue(reveal.exits)
        let morph = try XCTUnwrap(surface.morph(layout.core.paint(of: glass).morph))
        XCTAssertEqual(morph.stops.map(\.at), [-0.5, 0, 1, 1.5])
        XCTAssertEqual(morph.stops.map(\.scale), [0, 0, 1, 1])
        XCTAssertEqual(morph.anchor, CGPoint(x: 0.5, y: 0.5))
    }

    func testTheFloatingSeekBarKeepsHorizontalDragsWhileVerticalOnesMoveTheCard() throws {
        let fixture = try fixture()
        try float(fixture, by: CGVector(dx: 300, dy: 400))
        let seek = try frame(fixture, "player-media-seek")
        let start = CGPoint(x: seek.minX + 60, y: seek.midY)
        let end = grab(fixture, at: start, by: CGVector(dx: 3, dy: 0))
        XCTAssertNil(fixture.widget.surface.manipulation)
        XCTAssertEqual(drop(fixture, at: end).filter { $0.hasPrefix("media seek ") }.count, 1)
        let card = try frame(fixture, "media-card")
        drag(fixture, at: start, by: CGVector(dx: 0, dy: 40))
        Self.assertRect(try frame(fixture, "media-card"), card.offsetBy(dx: 0, dy: 40))
        XCTAssertTrue(has(fixture, "media-card-glass"))
    }

    func testCornersScaleTheFloatingCardFromHalfToOnePointSixAboutTheOppositeCorner() throws {
        let fixture = try fixture()
        let cu = Self.cu
        try float(fixture, by: CGVector(dx: 300, dy: 400))
        let card = try frame(fixture, "media-card")
        let corner = try recipe(fixture, "media-card-resize-se")
        XCTAssertEqual(corner.mode, .scale)
        XCTAssertEqual(corner.resizeMask, 10)
        XCTAssertEqual(corner.target, VitreusFixture.key("media-card"))
        XCTAssertEqual(corner.minimum.width, 154 * cu, accuracy: 1e-3)
        XCTAssertEqual(corner.minimum.height, 84 * cu, accuracy: 1e-3)
        XCTAssertEqual(corner.maximum.width, 492.8 * cu, accuracy: 1e-3)
        XCTAssertEqual(corner.maximum.height, 268.8 * cu, accuracy: 1e-3)
        try drag(fixture, key: "media-card-resize-se", by: CGVector(dx: -600, dy: -600))
        let small = try frame(fixture, "media-card")
        XCTAssertEqual(small.width / (308 * cu), 0.5, accuracy: 1e-6)
        XCTAssertEqual(small.height / (168 * cu), 0.5, accuracy: 1e-6)
        XCTAssertEqual(small.minX, card.minX, accuracy: 0.01)
        XCTAssertEqual(small.minY, card.minY, accuracy: 0.01)
        fixture.widget.surface.finishSettle()
        try drag(fixture, key: "media-card-resize-nw", by: CGVector(dx: -1200, dy: -1200))
        let large = try frame(fixture, "media-card")
        XCTAssertEqual(large.width / (308 * cu), 1.6, accuracy: 1e-6)
        XCTAssertEqual(large.height / (168 * cu), 1.6, accuracy: 1e-6)
        XCTAssertEqual(large.maxX, small.maxX, accuracy: 0.01)
        XCTAssertEqual(large.maxY, small.maxY, accuracy: 0.01)
        XCTAssertEqual(try frame(fixture, "player-media").width, 288 * cu * 1.6, accuracy: 0.01)
        Self.assertRect(try frame(fixture, "media-card-glass"), large)
        XCTAssertEqual(Double(try paint(fixture, "media-card-glass").cornerRadius), 26 * cu, accuracy: 1e-3)
    }

    func testThePinDocksTheCardAtFullSizeAndOpensThePlayerDrawerOnThisDisplay() throws {
        let fixture = try fixture()
        try float(fixture, by: CGVector(dx: 300, dy: 400))
        try drag(fixture, key: "media-card-resize-se", by: CGVector(dx: -600, dy: -600))
        VitreusFixture.trigger(fixture.widget.instance, "drawer-close", fixture.bar.monitorId)
        show(fixture)
        XCTAssertFalse(has(fixture, "drawer-content-player"))
        XCTAssertTrue(has(fixture, "media-card-glass"))
        let pin = try frame(fixture, "media-card-pin")
        let index = fixture.widget.events.count
        fixture.widget.surface.press(at: CGPoint(x: pin.midX, y: pin.midY))
        fixture.widget.surface.release(at: CGPoint(x: pin.midX, y: pin.midY))
        XCTAssertEqual(
            deliver(fixture, from: index),
            ["shell trigger vitreus drawer-selected " + fixture.bar.monitorId]
        )
        XCTAssertTrue(has(fixture, "drawer-content-player"))
        XCTAssertFalse(has(fixture, "media-card-glass"))
        XCTAssertFalse(has(fixture, "media-card-pin"))
        Self.assertRect(try frame(fixture, "media-card"), try docked(fixture))
        XCTAssertEqual(try commit(fixture), "pin-1")
        XCTAssertEqual(try frame(fixture, "drawer-content-player").height, (55.5 + 14 + 156) * Self.cu, accuracy: 0.01)
        XCTAssertEqual(try paint(fixture, "player-media-plate").opacity, 1)
    }

    func testTheAlbumReturnsToItsVisibleSlotAndTheWidgetRedocksItsSections() throws {
        let fixture = try fixture()
        let home = try docked(fixture)
        let fullHeight = try frame(fixture, "drawer-content-player").height
        func place(_ origin: CGPoint) throws {
            let rect = try frame(fixture, "media-card")
            drag(fixture, at: try cover(fixture), by: CGVector(dx: origin.x - rect.minX, dy: origin.y - rect.minY))
            fixture.widget.surface.finishSettle()
        }
        try float(fixture, by: CGVector(dx: 300, dy: 400))
        XCTAssertEqual(try frame(fixture, "drawer-content-player").height, fullHeight - 156 * Self.cu, accuracy: 0.01)
        VitreusFixture.trigger(fixture.widget.instance, "drawer-close", fixture.bar.monitorId)
        show(fixture)
        try place(home.origin)
        XCTAssertTrue(has(fixture, "media-card-glass"))
        VitreusFixture.trigger(fixture.widget.instance, "drawer-player", fixture.bar.monitorId)
        show(fixture)
        XCTAssertFalse(has(fixture, "media-card-glass"))
        Self.assertRect(try frame(fixture, "media-card"), home)
        try float(fixture, by: CGVector(dx: 300, dy: 400))
        try place(CGPoint(x: home.minX + 130, y: home.minY + 140))
        XCTAssertTrue(has(fixture, "media-card-glass"))
        try place(CGPoint(x: home.minX + 5, y: home.minY + 5))
        XCTAssertFalse(has(fixture, "media-card-glass"))
        Self.assertRect(try frame(fixture, "media-card"), home)
        XCTAssertTrue(try commit(fixture).hasPrefix("placement-"))
        XCTAssertEqual(try frame(fixture, "drawer-content-player").height, fullHeight, accuracy: 0.01)
    }

    func testTheCardGlassAndTheDeskGlassEachFollowOnlyTheirOwnTarget() throws {
        let fixture = try fixture(desk: true)
        try float(fixture, by: CGVector(dx: -500, dy: 400))
        let surface = fixture.widget.surface
        let card = try element(fixture, "media-card")
        let desk = try element(fixture, "desk")
        let glass = try element(fixture, "media-card-glass")
        let shape = try element(fixture, "desk-shape")
        let edge = try [
            "desk-bulge",
            "desk-ripple-break-top",
            "desk-ripple-break-bottom",
            "desk-stray",
            "desk-ripple-return-top",
            "desk-ripple-return-bottom"
        ].map { try element(fixture, $0) }
        XCTAssertEqual(Set(try children(fixture, of: "desk-glass")), Set([shape, glass] + edge))
        XCTAssertEqual(surface.layout.core.parent(of: glass), try element(fixture, "desk-glass"))
        XCTAssertEqual(surface.followedTarget(of: glass), card)
        XCTAssertEqual(surface.followedTarget(of: shape), desk)
        func moving(_ handle: ElementHandle) -> Bool {
            ShellLayerScene.engineQueue.sync {
                !(surface.scene.shapeTracks.follows[handle.slot]?.presentation.isIdentity ?? true)
            }
        }
        let grip = try frame(fixture, "grip")
        var held = grab(fixture, at: CGPoint(x: grip.midX, y: grip.midY), by: CGVector(dx: -80, dy: 60))
        XCTAssertEqual(surface.manipulation?.target, desk)
        XCTAssertTrue(moving(shape))
        XCTAssertFalse(moving(glass))
        drop(fixture, at: held)
        surface.finishSettle()
        held = grab(fixture, at: try cover(fixture), by: CGVector(dx: 120, dy: -40))
        XCTAssertEqual(surface.manipulation?.target, card)
        XCTAssertTrue(moving(glass))
        XCTAssertFalse(moving(shape))
        drop(fixture, at: held)
    }
}

extension ShellVitreusMediaCardTests {
    func pulse(_ fixture: Fixture) throws -> ShellPulseRecipe {
        try XCTUnwrap(ShellPulseRecipe(fixture.widget.text.string(paint(fixture, "player-media-cover").pulse)))
    }

    func timers(_ fixture: Fixture) -> [VitreusRequest] {
        VitreusFixture.drain(fixture.widget).filter { $0.kind == OMNI_SERVICE_TIMER }
    }

    func testATitleChangePulsesTheCoverOnceAndBurstsSparksUntilTheirLifetimeEnds() throws {
        let fixture = try fixture(artwork: "/nonexistent/first.png")
        XCTAssertEqual(try paint(fixture, "player-media-cover").pulse, 0)
        show(fixture)
        XCTAssertEqual(try paint(fixture, "player-media-cover").pulse, 0)
        XCTAssertEqual(timers(fixture).count, 0)
        play(fixture, "Second song", artwork: "/nonexistent/first.png")
        show(fixture)
        let first = try pulse(fixture)
        XCTAssertEqual(first.duration, 0.73, accuracy: 1e-6)
        XCTAssertEqual(first.rotate.count, 96)
        XCTAssertEqual(first.rotate.first, 0)
        XCTAssertEqual(first.rotate.last, 0)
        XCTAssertEqual(first.rotate.min() ?? 0, -12, accuracy: 0.05)
        XCTAssertEqual(first.scale.min() ?? 0, -0.3, accuracy: 0.002)
        XCTAssertEqual(first.rotate[90] / -12, first.scale[90] / -0.3, accuracy: 1e-4)
        XCTAssertGreaterThan(first.rotate[90], -0.2)
        let sparks = try content(fixture, "media-card-sparks-1")
        let burst = try frame(fixture, "media-card-sparks-1"), centre = try cover(fixture)
        XCTAssertEqual(burst.midX, centre.x, accuracy: 0.01)
        XCTAssertEqual(burst.midY, centre.y, accuracy: 0.01)
        XCTAssertEqual(fixture.widget.text.string(sparks.text), "vitreus-sparks.metal")
        XCTAssertEqual(sparks.rate, 60)
        Self.assertValues(sparks.params, SIMD4(1, 1, 0, 0))
        let pending = timers(fixture)
        XCTAssertEqual(pending.map(\.seconds), [1.1])
        play(fixture, "Second song", artwork: "/nonexistent/second.png")
        show(fixture)
        XCTAssertEqual(try pulse(fixture).key, first.key)
        XCTAssertEqual(timers(fixture).count, 0)
        VitreusFixture.complete(fixture.widget, try XCTUnwrap(pending.first))
        show(fixture)
        XCTAssertFalse(has(fixture, "media-card-sparks-1"))
        XCTAssertEqual(try paint(fixture, "player-media-cover").pulse, 0)
        play(fixture, "Third song", artwork: "/nonexistent/second.png")
        show(fixture)
        XCTAssertNotEqual(try pulse(fixture).key, first.key)
        XCTAssertTrue(has(fixture, "media-card-sparks-2"))
        fixture.widget.set("media") { $0.null() }
        show(fixture)
        play(fixture, "Fourth song", artwork: "/nonexistent/second.png")
        show(fixture)
        XCTAssertEqual(try paint(fixture, "player-media-cover").pulse, 0)
        XCTAssertFalse(has(fixture, "media-card-sparks-3"))
    }

    func testTheCoverEffectAndSeekWaveFollowPlaybackWhileTheSpectrumStaysGated() throws {
        let fixture = try fixture(artwork: "/nonexistent/cover.png")
        let cu = Float(Self.cu)
        func effect() throws -> ShellEffectRecipe {
            try XCTUnwrap(ShellEffectRecipe(fixture.widget.text
                    .string(content(fixture, "player-media-cover-fx").effect)))
        }
        XCTAssertEqual(try effect().source, "vitreus-cover.metal")
        XCTAssertEqual(try effect().rate, 0)
        XCTAssertEqual(Float(try effect().bleed), 12 * cu, accuracy: 1e-3)
        Self.assertValues(try effect().values, SIMD4(1, 12 * cu, 0.6, 0))
        var wave = try content(fixture, "player-media-seek-wave")
        XCTAssertEqual(fixture.widget.text.string(wave.text), "vitreus-seek.metal")
        XCTAssertEqual(wave.rate, 60)
        Self.assertValues(wave.params, SIMD4(cu, 28, 0, 0))
        play(fixture, "First song", artwork: "/nonexistent/cover.png", playing: false)
        show(fixture)
        XCTAssertEqual(try effect().values.x, 0.3, accuracy: 1e-6)
        wave = try content(fixture, "player-media-seek-wave")
        XCTAssertEqual(wave.rate, 0)
        XCTAssertEqual(wave.params.y, 24)
        play(fixture, "First song", artwork: "/nonexistent/cover.png", duration: nil)
        show(fixture)
        wave = try content(fixture, "player-media-seek-wave")
        XCTAssertEqual(wave.params.y, 192)
        XCTAssertEqual(wave.params.w, 1)
        let deps = fixture.widget.output().withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self).deps }
        XCTAssertEqual(deps & ShellDataKey.spectrum.bit, 0)
        VitreusFixture.settings(
            fixture.widget,
            ["pieces": .strings(["workspaces", "title"]), "visualiser": .bool(true)]
        )
        show(fixture)
        let on = fixture.widget.output().withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self).deps }
        XCTAssertNotEqual(on & ShellDataKey.spectrum.bit, 0)
    }

    func testTheFloatingCardSnapshotsAsItsOwnGlassOverTheDesktop() throws {
        let fixture = try fixture(scale: 1)
        try float(fixture, by: CGVector(dx: 300, dy: 400))
        let body = try VitreusFixture.body(fixture.widget, key: "desk-glass")
        guard ShellLayerScene.engineQueue.sync(execute: { body.nativeAvailable }) else {
            throw XCTSkip("Native glass is unavailable")
        }
        let card = try frame(fixture, "media-card")
        let crop = card.insetBy(dx: -40, dy: -40).integral
        let pixels = try VitreusFixture.pixels(fixture.widget, crop: crop, scale: 1, shadowless: true)
        func alpha(_ x: CGFloat, _ y: CGFloat) -> UInt8 {
            pixels[(Int(y - crop.minY) * Int(crop.width) + Int(x - crop.minX)) * 4 + 3]
        }
        XCTAssertGreaterThan(alpha(card.midX, card.maxY - 4), 0)
        XCTAssertGreaterThan(alpha(card.minX + 4, card.midY), 0)
        XCTAssertEqual(alpha(card.minX - 30, card.midY), 0)
        XCTAssertEqual(alpha(card.maxX + 30, card.midY), 0)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: Int(crop.width), height: Int(crop.height), bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: Int(crop.width) * 4, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo.byteOrder32Little
                .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        try ShellVitreusDeskTests.write(image, name: "vitreus-media-card-1x")
    }
}
