// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

private let deskShapeNames = [
    "desk-shape", "desk-bulge", "desk-ripple-break-top", "desk-ripple-break-bottom", "desk-stray",
    "desk-ripple-return-top", "desk-ripple-return-bottom"
]

@MainActor
final class ShellVitreusPanesTests: XCTestCase {
    typealias Fixture = ShellManipulationSurfaceTests.Fixture
    typealias Clock = ShellManipulationSurfaceTests.Clock

    private static let followerBody = """
    local open=ctx.data.open
    return ui.stack{w=600,h=400,
        ui.box{decorative=true,w=600,h=400,fill='surface'},
        open and ui.stack{key='desk',align='topLeading',dx=200,dy=100,w=200,h=160,
            manipulationFollow={response=0.363,bounce=0.42},
            ui.box{key='grip',align='topLeading',w=200,h=20,onGesture=function() end,
                gesture={axis='free',track={mode='move',target='desk',bounds={w=600,h=400},
                    min={w=200,h=160},max={w=200,h=160}}}}} or nil,
        ui.glass{key='panes',w=600,h=400,align='topLeading',blend=0,
            open and ui.shape{key='card',follow='desk',align='topLeading',dx=200,dy=100,w=200,h=160,radius=16,
                reveal={response=0.482,bounce=0.31},
                morph={anchor={x=1,y=0.5},stops={{at=0,scale=0.05},{at=1,scale=1}}}} or nil}}
    """

    func shell() throws -> URL {
        let shell = try VitreusFixture.shell()
        let folder = shell.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return shell
    }

    private func open(_ fixture: Fixture, _ open: Bool) {
        var writer = ShellValueWriter()
        writer.bool(open)
        _ = writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(fixture.script.instance, "open", $0.baseAddress, $0.count)
        }
        fixture.render()
    }

    private func handle(_ fixture: Fixture, _ name: String) throws -> ElementHandle {
        let layout = fixture.surface.layout
        let key = VitreusFixture.key(name)
        return try XCTUnwrap(layout.core.elements { _ in true }.first { layout.core.key(of: $0) == key }, name)
    }

    private func attach(_ container: CALayer, width: Int, height: Int) throws -> ShellOffscreenRenderer {
        try ShellLayerScene.engineQueue.sync {
            container.removeFromSuperlayer()
            return try ShellOffscreenRenderer(root: container, width: width, height: height)
        }
    }

    private func settles(_ surface: ShellWidgetSurface, _ shape: ElementHandle) throws
        -> [(completion: ShellManipulationCompletion, animation: CAAnimation)]
    {
        let scene = surface.scene
        return try ShellLayerScene.engineQueue.sync {
            let body = try XCTUnwrap(scene.parents[shape.slot].flatMap { scene.glassBodies[$0] })
            return body.lockstepLayers(shape.slot).flatMap { layer in
                (layer.animationKeys() ?? []).compactMap { key in
                    layer.animation(forKey: key).flatMap { animation in
                        (animation.delegate as? ShellManipulationCompletion).map { ($0, animation) }
                    }
                }
            }
        }
    }

    private func complete(_ surface: ShellWidgetSurface, _ shape: ElementHandle) async throws {
        let grabbed = try settles(surface, shape)
        XCTAssertFalse(grabbed.isEmpty, "no reveal settle survived the grab")
        for settle in grabbed {
            settle.completion.animationDidStop(settle.animation, finished: true)
        }
        ShellLayerScene.engineQueue.sync {}
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func children(_ widget: ShellRenderedWidget, of name: String) throws -> [ElementHandle] {
        let layout = widget.surface.layout
        let parent = try VitreusFixture.element(widget, key: name)
        return layout.core.elements { _ in true }.filter { layout.core.parent(of: $0) == parent }
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect, line: UInt = #line) {
        for (value, target) in [
            (actual.minX, expected.minX), (actual.minY, expected.minY), (actual.width, expected.width),
            (actual.height, expected.height)
        ] {
            XCTAssertEqual(value, target, accuracy: 0.01, line: line)
        }
    }

    func testAFollowingShapeRevealStillSettlesAfterAGrabRebuildsItsComposite() async throws {
        let clock = Clock()
        let fixture = try Fixture(Self.followerBody, animations: true) { clock.now }
        let surface = fixture.surface
        let renderer = try attach(surface.scene.container, width: 600, height: 400)
        clock.now += 1
        open(fixture, true)
        let card = try handle(fixture, "card")
        XCTAssertNotNil(surface.reveals[card]?.plan)
        XCTAssertFalse(try settles(surface, card).isEmpty, "opened")
        clock.now += 0.05
        surface.press(at: CGPoint(x: 300, y: 110), timestamp: 0)
        surface.drag(to: CGPoint(x: 320, y: 130), screen: .zero, timestamp: 0.01)
        XCTAssertEqual(surface.manipulation?.target, try handle(fixture, "desk"))
        let mode = ShellLayerScene.engineQueue.sync { surface.scene.shapeTracks.follows[card.slot]?.mode }
        XCTAssertEqual(mode, .composite)
        try await complete(surface, card)
        XCTAssertNil(surface.reveals[card]?.plan)
        XCTAssertNil(ShellLayerScene.engineQueue.sync { surface.scene.presence.revealPlans[card.slot] })
        surface.cancelInput()
        withExtendedLifetime(renderer) {}
    }

    func testThePanesBodyHoldsTheFollowingDeskShapeWithTheVitreusIslandRecipe() throws {
        let shell = try shell()
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let bar = try ShellRenderedWidget(
            source: VitreusFixture.source(shell),
            resources: VitreusFixture.resources(shell)
        )
        VitreusFixture.show(bar)
        assertRect(try VitreusFixture.frame(bar, key: "desk-glass"), display)
        XCTAssertEqual(try children(bar, of: "desk-glass"), [])
        let widget = try VitreusFixture.desk(shell, scale: 1)
        let surface = widget.surface
        let layout = surface.layout
        let (rect, _) = ShellVitreusDeskTests.envelope(width: 1920, height: 1080)
        let glass = try VitreusFixture.element(widget, key: "desk-glass")
        let shape = try VitreusFixture.element(widget, key: "desk-shape")
        let desk = try VitreusFixture.element(widget, key: "desk")
        assertRect(try VitreusFixture.frame(widget, key: "desk-glass"), display)
        assertRect(try VitreusFixture.frame(widget, key: "desk-shape"), rect)
        XCTAssertEqual(
            Set(try children(widget, of: "desk-glass").map { layout.core.key(of: $0) }),
            Set(deskShapeNames.map(VitreusFixture.key))
        )
        let recipe = try XCTUnwrap(ShellGlassRecipe(widget.text.string(layout.core.content(of: glass).text)))
        XCTAssertEqual(recipe.blend, 26 * 1.35, accuracy: 1e-6)
        XCTAssertEqual(recipe.shadowOffset, CGPoint(x: 0, y: 7))
        XCTAssertEqual(recipe.rim, 0.1, accuracy: 1e-6)
        XCTAssertEqual(layout.core.paint(of: glass).shadowRadius, 20)
        XCTAssertEqual(layout.core.paint(of: shape).cornerRadius, 35.1, accuracy: 1e-3)
        XCTAssertEqual(layout.core.content(of: shape).glassFollow, VitreusFixture.key("desk"))
        XCTAssertFalse(layout.core.content(of: shape).glassFollowFixedRadius)
        XCTAssertEqual(surface.followedTarget(of: shape), desk)
        let reveal = try XCTUnwrap(surface.reveal(layout.core.paint(of: shape).reveal))
        XCTAssertEqual(reveal.response, 0.482, accuracy: 1e-4)
        XCTAssertEqual(reveal.bounce, 0.31, accuracy: 1e-4)
        XCTAssertEqual(reveal.delay, 0)
        XCTAssertEqual(reveal.hold, 0)
        XCTAssertTrue(reveal.exits)
        XCTAssertFalse(surface.isWithin(glass, desk))
        XCTAssertFalse(surface.isWithin(shape, desk))
        VitreusFixture.trigger(widget.instance, "desk-close", nil)
        VitreusFixture.show(widget)
        assertRect(try VitreusFixture.frame(widget, key: "desk-glass"), display)
        XCTAssertEqual(try children(widget, of: "desk-glass"), [])
    }

    func testGrabbingTheDeskWhileItOpensStillSettlesItsGlassReveal() async throws {
        let shell = try shell()
        let widget = try ShellRenderedWidget(
            source: VitreusFixture.source(shell), scale: 1, resources: VitreusFixture.resources(shell, animations: true)
        )
        let clock = Clock()
        widget.surface.clock = { clock.now }
        let renderer = try attach(widget.surface.scene.container, width: 1920, height: 1080)
        VitreusFixture.show(widget)
        clock.now = CACurrentMediaTime() + 1
        VitreusFixture.trigger(widget.instance, "desk-open", VitreusFixture.bar().monitorId)
        VitreusFixture.show(widget)
        let shape = try VitreusFixture.element(widget, key: "desk-shape")
        XCTAssertNotNil(widget.surface.reveals[shape]?.plan)
        clock.now += 0.05
        let grip = try CGRect(widget.surface.presentedFrame(of: VitreusFixture.element(widget, key: "grip")))
        VitreusFixture.grab(
            widget, at: CGPoint(x: grip.midX, y: grip.midY), to: CGPoint(x: grip.midX - 60, y: grip.midY + 30)
        )
        XCTAssertEqual(widget.surface.manipulation?.target, try VitreusFixture.element(widget, key: "desk"))
        let mode = ShellLayerScene.engineQueue.sync { widget.surface.scene.shapeTracks.follows[shape.slot]?.mode }
        XCTAssertEqual(mode, .composite)
        try await complete(widget.surface, shape)
        XCTAssertNil(widget.surface.reveals[shape]?.plan)
        XCTAssertNotNil(widget.surface.manipulation)
        widget.surface.cancelInput()
        withExtendedLifetime(renderer) {}
    }
}
