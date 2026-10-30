// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellVitreusLiquidTests: XCTestCase {
    private let frames = ShellVitreusFrameTests()
    private let layouts = ["left", "right", "ftop", "fbottom", "seg"]

    private func open(_ fixture: ShellVitreusFrameTests.Fixture) {
        VitreusFixture.trigger(fixture.widget.instance, "desk-open", fixture.bar.monitorId)
        frames.show(fixture)
        ShellLayerScene.engineQueue.sync {}
    }

    private func morph(_ widget: ShellRenderedWidget, _ name: String) throws -> ShellMorphRecipe {
        let handle = try VitreusFixture.element(widget, key: name)
        return try XCTUnwrap(ShellMorphRecipe(widget.text.string(widget.surface.layout.core.paint(of: handle).morph)))
    }

    func testFrameLayoutsPutOneDeskInTheBarBodyWithContentSizedTargetsAndIndependentAdhesion() throws {
        for edge in layouts {
            let fixture = try frames.fixture(edge)
            defer { VitreusFixture.remove(fixture.shell) }
            open(fixture)
            let widget = fixture.widget
            let layout = widget.surface.layout
            let plate = try VitreusFixture.element(widget, key: "desk-shape")
            XCTAssertEqual(layout.core.parent(of: plate), try VitreusFixture.element(widget, key: "bar"), edge)
            XCTAssertEqual(layout.core.content(of: plate).glassFollow, 0)
            XCTAssertFalse(frames.has(fixture, "desk-glass"))
            let target = try frames.frame(fixture, "desk")
            let du = 1.5525 * 0.8
            XCTAssertEqual(target.width, 340 * du, accuracy: 0.001, edge)
            let source = try XCTUnwrap(morph(widget, "desk-shape").source)
            let thin = 10.8, strip = 62.1
            let right = edge == "right" ? strip : thin
            XCTAssertEqual(target.maxX, 1920 - right, accuracy: 0.001, edge)
            XCTAssertEqual(source.target, VitreusFixture.key("desk"))
            XCTAssertEqual(source.edge, .right)
            XCTAssertFalse(source.contact)
            XCTAssertEqual(source.from, right + 14 * du, accuracy: 0.001)
            XCTAssertEqual(source.span, 50 * du, accuracy: 0.001)
            XCTAssertEqual(
                try XCTUnwrap(source.adhere.left),
                (edge == "left" ? strip : thin) + 14 * du,
                accuracy: 0.001
            )
            XCTAssertEqual(try XCTUnwrap(source.adhere.top), (edge == "ftop" ? strip : thin) + 14 * du, accuracy: 0.001)
            XCTAssertEqual(
                try XCTUnwrap(source.adhere.bottom),
                (edge == "fbottom" ? strip : thin) + 14 * du,
                accuracy: 0.001
            )
            let grip = try frames.content(fixture, "grip")
            let recipe = try XCTUnwrap(ShellManipulationRecipe(widget.text.string(grip.gestureTrack)))
            XCTAssertEqual(recipe.inset.width, 0)
            XCTAssertEqual(recipe.bounds.minX, edge == "left" ? strip : thin, accuracy: 0.001)
            XCTAssertFalse(widget.surface.containsShape(at: CGPoint(x: 960, y: 540)))
            XCTAssertFalse(widget.surface.islandRegions().contains { $0.contains(CGPoint(x: 960, y: 540)) })
        }
    }

    func testLiquidTriggersCaptureContactAndOnlyTheOpenDeskDeclaresBounces() throws {
        let fixture = try frames.fixture("left")
        defer { VitreusFixture.remove(fixture.shell) }
        open(fixture)
        let widget = fixture.widget
        let bulge = try morph(widget, "desk-bulge")
        XCTAssertEqual(bulge.source?.contact, true)
        XCTAssertNil(bulge.source?.pads)
        XCTAssertEqual(bulge.impulses.map(\.velocity), [-280, 80, -200])
        XCTAssertEqual(bulge.impulses.map(\.time), [0.7, 0.7, 0.05])
        XCTAssertEqual(bulge.impulses.map(\.rising), [true, false, false])
        for name in [
            "desk-ripple-break-top",
            "desk-ripple-break-bottom",
            "desk-stray",
            "desk-ripple-return-top",
            "desk-ripple-return-bottom"
        ] {
            let trigger = try XCTUnwrap(morph(widget, name).trigger)
            XCTAssertTrue(trigger.contact)
            XCTAssertEqual(trigger.shape, VitreusFixture.key("desk-bulge"))
            XCTAssertEqual(trigger.at, name.contains("return") ? 0.05 : 0.7)
            XCTAssertEqual(trigger.rising, !name.contains("return"))
            XCTAssertFalse(try frames.content(fixture, name).glassHit)
        }
        VitreusFixture.trigger(widget.instance, "desk-close", nil)
        frames.show(fixture)
        for name in ["desk", "desk-shape", "desk-bulge", "desk-stray", "desk-ripple-return-top"] {
            XCTAssertFalse(frames.has(fixture, name), name)
        }
    }

    func testFrameDragUsesTheSameBoundRectForRenderingAndInputWithoutPublishingLuau() throws {
        let fixture = try frames.fixture("seg")
        defer { VitreusFixture.remove(fixture.shell) }
        open(fixture)
        let widget = fixture.widget
        let surface = widget.surface
        let grip = try frames.frame(fixture, "grip")
        let start = CGPoint(x: grip.midX, y: grip.midY)
        let original = widget.output()
        surface.press(at: start, timestamp: 0)
        surface.drag(to: CGPoint(x: start.x - 70, y: start.y + 40), screen: .zero, timestamp: 0.01)
        ShellLayerScene.engineQueue.sync {}
        XCTAssertNotNil(surface.manipulation)
        XCTAssertEqual(widget.output(), original)
        let shape = try VitreusFixture.element(widget, key: "desk-shape")
        let rendered = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(surface.scene.shapeTracks.entries[shape.slot]).shape(at: .infinity)
        }
        let body = try frames.frame(fixture, "bar")
        let regions = surface.glassRegions(
            shape, clippedTo: body, in: surface.presentation, excluding: surface.degenerateRingBodies()
        )
        ShellBoundSurfaceFixture.assertRect(
            try XCTUnwrap(regions.first),
            rendered.rect.intersection(body),
            accuracy: 0.001
        )
        let centre = CGPoint(x: body.minX + rendered.rect.midX, y: body.minY + rendered.rect.midY)
        XCTAssertTrue(surface.containsShape(at: centre))
        XCTAssertFalse(surface.containsShape(at: CGPoint(x: 960, y: 540)))
        surface.cancelInput()
    }

    func testIslandKeepsItsFollowedDeskAndBlendsTheEdgeLiquidAtTheScreenEdge() throws {
        let fixture = try frames.fixture("island")
        defer { VitreusFixture.remove(fixture.shell) }
        open(fixture)
        let widget = fixture.widget
        let layout = widget.surface.layout
        let glass = try VitreusFixture.element(widget, key: "desk-glass")
        let plate = try VitreusFixture.element(widget, key: "desk-shape")
        XCTAssertEqual(layout.core.parent(of: plate), glass)
        XCTAssertEqual(layout.core.content(of: plate).glassFollow, VitreusFixture.key("desk"))
        XCTAssertNil(try morph(widget, "desk-shape").source)
        let du = 1.5525 * 0.8
        XCTAssertEqual(try frames.frame(fixture, "desk").width, 353 * du, accuracy: 0.001)
        let recipe = try XCTUnwrap(ShellGlassRecipe(widget.text.string(layout.core.content(of: glass).text)))
        XCTAssertEqual(recipe.blend, 26 * 1.35, accuracy: 1e-6)
        let source = try XCTUnwrap(morph(widget, "desk-bulge").source)
        XCTAssertEqual(source.target, VitreusFixture.key("desk"))
        XCTAssertEqual(source.edge, .right)
        XCTAssertTrue(source.contact)
        XCTAssertEqual(source.from, 14 * du, accuracy: 0.001)
        XCTAssertEqual(source.span, 50 * du, accuracy: 0.001)
        XCTAssertEqual(try frames.frame(fixture, "desk-bulge").midX, 1920, accuracy: 0.001)
        for name in [
            "desk-bulge",
            "desk-ripple-break-top",
            "desk-ripple-break-bottom",
            "desk-stray",
            "desk-ripple-return-top",
            "desk-ripple-return-bottom"
        ] {
            XCTAssertEqual(layout.core.parent(of: try VitreusFixture.element(widget, key: name)), glass, name)
        }
    }

    func testPullingTheIslandDeskOffTheScreenEdgeSwellsTheBulgeBetweenThem() throws {
        let fixture = try frames.fixture("island")
        defer { VitreusFixture.remove(fixture.shell) }
        open(fixture)
        let widget = fixture.widget
        let surface = widget.surface
        let bulge = try VitreusFixture.element(widget, key: "desk-bulge")
        func width() throws -> CGFloat {
            try ShellLayerScene.engineQueue.sync {
                try XCTUnwrap(surface.scene.shapeTracks.entries[bulge.slot]).shape(at: .infinity)
            }.rect.width
        }
        XCTAssertLessThan(try width(), 2)
        let grip = try frames.frame(fixture, "grip")
        let start = CGPoint(x: grip.midX, y: grip.midY)
        surface.press(at: start, timestamp: 0)
        surface.drag(to: CGPoint(x: start.x - 45, y: start.y), screen: .zero, timestamp: 0.01)
        ShellLayerScene.engineQueue.sync {}
        XCTAssertNotNil(surface.manipulation)
        XCTAssertGreaterThan(try width(), 30)
        surface.cancelInput()
    }

    func testASettledDetachedIslandDeskLeavesNoLiquidOnTheScreenEdge() throws {
        let fixture = try frames.fixture("island")
        defer { VitreusFixture.remove(fixture.shell) }
        open(fixture)
        let widget = fixture.widget
        let scene = widget.surface.scene
        func settled(_ name: String) throws -> CGRect {
            let slot = try VitreusFixture.element(widget, key: name).slot
            return try ShellLayerScene.engineQueue.sync {
                try XCTUnwrap(scene.shapeTracks.entries[slot], name).shape(at: .infinity)
            }.rect
        }
        XCTAssertEqual(try settled("desk-bulge").width, 0.6, accuracy: 0.001)
        let home = try frames.frame(fixture, "desk")
        try VitreusFixture.drag(widget, key: "grip", by: CGVector(dx: -400, dy: 0))
        XCTAssertNil(widget.surface.manipulation)
        ShellBoundSurfaceFixture.assertRect(
            try frames.frame(fixture, "desk"),
            home.offsetBy(dx: -400, dy: 0),
            accuracy: 0.01
        )
        for name in [
            "desk-bulge",
            "desk-ripple-break-top",
            "desk-ripple-break-bottom",
            "desk-stray",
            "desk-ripple-return-top",
            "desk-ripple-return-bottom"
        ] {
            let rect = try settled(name)
            XCTAssertEqual(rect.width * rect.height, 0, "\(name) \(rect)")
        }
        let body = try VitreusFixture.body(widget)
        try ShellLayerScene.engineQueue.sync {
            guard body.nativeAvailable else { throw XCTSkip(body.failure ?? "Native glass is unavailable") }
        }
        let pixels = try VitreusFixture.pixels(widget, crop: CGRect(x: 1856, y: 360, width: 64, height: 360), scale: 2)
        let alpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }.max() ?? 0
        XCTAssertEqual(alpha, 0, "Glass is drawn within 64 pt of the screen edge after the Desk detached")
    }

    func testExistingDockAndAddonAdhesionSharesTheFrameBodyOnEveryLayout() throws {
        let docks = ShellVitreusDockTests()
        for edge in layouts {
            let widget = try docks.island([
                "layout": .string(edge), "pins": .strings([ShellVitreusDockTests.safari]), "addons": .strings(["notes"])
            ])
            _ = try docks.press(widget, key: "addon-pin-notes")
            let layout = widget.surface.layout
            let body = try VitreusFixture.element(widget, key: "bar")
            for name in ["dock-pill", "addon-pill", "addon-drawer"] {
                let target = try VitreusFixture.element(widget, key: name)
                let shape = try VitreusFixture.element(widget, key: name + "-glass")
                XCTAssertEqual(layout.core.parent(of: shape), body, edge)
                XCTAssertEqual(layout.core.content(of: shape).glassFollow, VitreusFixture.key(name))
                let glass = CGRect(layout.core.absoluteFrame(of: shape))
                let content = CGRect(layout.core.absoluteFrame(of: target))
                XCTAssertLessThanOrEqual(Float(glass.minX).nextDown, Float(content.minX), name + " " + edge)
                XCTAssertLessThanOrEqual(Float(glass.minY).nextDown, Float(content.minY), name + " " + edge)
                XCTAssertGreaterThanOrEqual(Float(glass.maxX).nextUp, Float(content.maxX), name + " " + edge)
                XCTAssertGreaterThanOrEqual(Float(glass.maxY).nextUp, Float(content.maxY), name + " " + edge)
                XCTAssertGreaterThan(glass.width + glass.height, content.width + content.height)
            }
        }
    }

    func testFrameScaleCommitKeepsTheContentTargetAndScalesOnlyTheFreePadsAndRadius() throws {
        let fixture = try frames.fixture("right")
        defer { VitreusFixture.remove(fixture.shell) }
        open(fixture)
        let widget = fixture.widget
        let surface = widget.surface
        let before = try frames.frame(fixture, "desk")
        let handle = try frames.frame(fixture, "resize-nw")
        let start = CGPoint(x: handle.midX, y: handle.midY)
        let end = CGPoint(x: start.x + before.width * 0.3, y: start.y + before.height * 0.3)
        let eventStart = widget.events.count
        surface.press(at: start, timestamp: 0)
        surface.drag(to: end, screen: .zero, timestamp: 0.01)
        let proposed = try XCTUnwrap(surface.manipulation?.preview)
        surface.release(at: end, timestamp: 0.02)
        for event in widget.events.dropFirst(eventStart) { widget.invoke(event.action, event: event.event) }
        frames.show(fixture)
        let after = try frames.frame(fixture, "desk")
        ShellBoundSurfaceFixture.assertRect(after, proposed, accuracy: 0.001)
        let factor = after.width / before.width
        XCTAssertLessThan(factor, 1)
        let source = try XCTUnwrap(morph(widget, "desk-shape").source)
        XCTAssertEqual(try XCTUnwrap(source.pads?.right), 6.5 * 1.5525 * 0.8 * factor, accuracy: 0.001)
        XCTAssertEqual(source.from, 62.1 + 14 * 1.5525 * 0.8, accuracy: 0.001)
        let plate = try VitreusFixture.element(widget, key: "desk-shape")
        XCTAssertEqual(
            CGFloat(widget.surface.layout.core.paint(of: plate).cornerRadius),
            35.1 * factor,
            accuracy: 0.001
        )
    }

    func testSettlingBoundDeskDoesNotReserveTheTransparentCentre() throws {
        let fixture = try frames.fixture("left", animations: true)
        defer { VitreusFixture.remove(fixture.shell) }
        open(fixture)
        let surface = fixture.widget.surface
        let target = try VitreusFixture.element(fixture.widget, key: "desk")
        let frame = CGRect(surface.layout.core.absoluteFrame(of: target))
        var commands: [ShellLayerCommand] = []
        XCTAssertTrue(surface.settleFollow(target, to: frame, from: frame.offsetBy(dx: -100, dy: 40), into: &commands))
        surface.scene.submit(commands, animated: false)
        ShellLayerScene.engineQueue.sync {}
        XCTAssertNotNil(surface.follows[target]?.motion)
        let empty = CGPoint(x: 960, y: 540)
        XCTAssertFalse(surface.islandRegions().contains { $0.contains(empty) })
        XCTAssertFalse(surface.containsShape(at: empty))
        let shown = CGRect(surface.presentedFrame(of: target))
        XCTAssertTrue(surface.islandRegions().contains { $0.contains(CGPoint(x: shown.midX, y: shown.midY)) })
    }
}
