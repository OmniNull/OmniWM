// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellWidgetLayoutOwnershipTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let script: ShellScriptHostTests.Script
        let instance = ShellWidgetHost.InstanceState()
        let text = ShellTextStore()
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        private var sequence = 0

        init(_ source: String = """
        function render(ctx)
            return ui.box{ key = "root", w = ctx.data.seconds, h = 10, fill = "accent", onClick = "focus left" }
        end
        """) throws {
            script = try ShellScriptHostTests.Script(source)
        }

        @discardableResult
        func render(_ value: Double) -> Bool {
            XCTAssertEqual(omni_instance_set_number(script.instance, "seconds", value), OMNI_OK)
            XCTAssertEqual(script.render().status, OMNI_OK, script.message)
            let output = script.output
            text.ingest(wire: output)
            sequence += 1
            return instance.apply(ShellWidgetDelivery.Tree(nodes: output, sequence: sequence), text: text)
        }

        func mount(scale: CGFloat = 2) -> ShellWidgetSurface {
            let surface = ShellWidgetSurface(scale: scale, resources: resources, directories: [])
            XCTAssertTrue(surface.apply(instance.nodes, text: text))
            instance.surface = surface
            ShellLayerScene.engineQueue.sync {}
            return surface
        }
    }

    func testMeasuresBeforeMountAndReleasesTheHeadlessLayout() throws {
        let fixture = try Fixture()
        XCTAssertTrue(fixture.render(20))
        XCTAssertEqual(fixture.instance.size, CGSize(width: 20, height: 10))
        weak let measured = try XCTUnwrap(fixture.instance.unmountedLayout)
        XCTAssertTrue(fixture.render(30))
        XCTAssertTrue(fixture.instance.unmountedLayout === measured)
        XCTAssertEqual(fixture.instance.size, CGSize(width: 30, height: 10))

        let surface = fixture.mount()
        XCTAssertNil(measured)
        XCTAssertNil(fixture.instance.unmountedLayout)
        XCTAssertEqual(surface.size, fixture.instance.size)
        XCTAssertEqual(surface.command(at: CGPoint(x: 25, y: 5)), "focus left")
        let scene = surface.scene
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.layers.count }, 1)

        XCTAssertTrue(fixture.render(40))
        XCTAssertEqual(surface.size, CGSize(width: 40, height: 10))
        XCTAssertEqual(fixture.instance.size, surface.size)
        XCTAssertEqual(fixture.instance.sequences[ShellWidgetView.bar.rawValue], 3)
        XCTAssertNil(fixture.instance.unmountedLayout)
    }

    func testMountedUpdatesKeepLayerIdentityScrollAndInteractionState() throws {
        let fixture = try Fixture("""
        function render(ctx)
            return ui.column{ key = "root", w = 20, h = 10, scroll = true,
                fill = ctx.data.seconds == 1 and "accent" or "surface",
                ui.box{ key = "left", w = 20, h = 10, onClick = "focus left" },
                ui.box{ key = "right", w = 20, h = 10, onClick = "focus right" } }
        end
        """)
        XCTAssertTrue(fixture.render(1))
        let surface = fixture.mount()
        let root = surface.layout.core.rootHandle
        let scene = surface.scene
        let layer = try XCTUnwrap(ShellLayerScene.engineQueue.sync { scene.layers[root.slot] })
        let point = CGPoint(x: 5, y: 5)
        XCTAssertTrue(surface.scroll(at: point, event: ShellEvent(button: .none), content: CGPoint(x: 0, y: 10)))
        XCTAssertEqual(surface.command(at: point), "focus right")
        surface.focusAxis = .vertical
        surface.focused = surface.layout.core.hitTest(x: 5, y: 5) { $0.action != 0 }
        surface.press(at: point)
        let focused = surface.focused
        let pressed = surface.pressed

        XCTAssertFalse(fixture.render(2))
        XCTAssertEqual(surface.layout.core.rootHandle, root)
        XCTAssertEqual(surface.focused, focused)
        XCTAssertEqual(surface.pressed, pressed)
        XCTAssertEqual(surface.command(at: point), "focus right")
        XCTAssertTrue(ShellLayerScene.engineQueue.sync { scene.layers[root.slot] === layer })
        XCTAssertEqual(fixture.instance.sequences[ShellWidgetView.bar.rawValue], 2)
        XCTAssertNil(fixture.instance.unmountedLayout)
    }

    func testRemountUsesTheLatestTreeWithAndWithoutHeadlessUpdates() throws {
        let fixture = try Fixture()
        fixture.render(20)
        let first = fixture.mount()
        fixture.render(30)
        fixture.instance.surface = nil
        let remounted = fixture.mount()
        XCTAssertFalse(remounted === first)
        XCTAssertEqual(remounted.size, CGSize(width: 30, height: 10))
        XCTAssertEqual(remounted.command(at: CGPoint(x: 25, y: 5)), "focus left")

        fixture.instance.surface = nil
        XCTAssertTrue(fixture.render(40))
        weak let measured = try XCTUnwrap(fixture.instance.unmountedLayout)
        let resized = fixture.mount(scale: 1)
        XCTAssertNil(measured)
        XCTAssertEqual(resized.size, CGSize(width: 40, height: 10))
        XCTAssertEqual(resized.command(at: CGPoint(x: 35, y: 5)), "focus left")
        let replacement = fixture.mount(scale: 2)
        XCTAssertFalse(replacement === resized)
        XCTAssertEqual(replacement.size, fixture.instance.size)
        XCTAssertEqual(replacement.command(at: CGPoint(x: 35, y: 5)), "focus left")
    }

    func testResetRoutesToTheCurrentOwnerAndRedrawRebuildsTheMountedTree() throws {
        let fixture = try Fixture()
        fixture.render(20)
        let measured = try XCTUnwrap(fixture.instance.unmountedLayout)
        let oldMeasuredRoot = measured.core.rootHandle
        fixture.instance.reset(text: fixture.text)
        XCTAssertFalse(measured.core.contains(oldMeasuredRoot))
        XCTAssertEqual(measured.size, .zero)
        XCTAssertFalse(fixture.render(20))
        XCTAssertEqual(measured.size, fixture.instance.size)

        let surface = fixture.mount()
        let oldRoot = surface.layout.core.rootHandle
        surface.press(at: CGPoint(x: 5, y: 5))
        fixture.instance.reset(text: fixture.text)
        XCTAssertEqual(surface.size, .zero)
        XCTAssertEqual(surface.pressed, .none)
        XCTAssertFalse(surface.layout.core.contains(oldRoot))
        XCTAssertNil(fixture.instance.unmountedLayout)
        XCTAssertFalse(fixture.render(20))
        XCTAssertEqual(surface.command(at: CGPoint(x: 5, y: 5)), "focus left")

        fixture.instance.redraw(text: fixture.text)
        XCTAssertEqual(surface.size, fixture.instance.size)
        XCTAssertEqual(surface.command(at: CGPoint(x: 5, y: 5)), "focus left")
        let scene = surface.scene
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.layers.count }, 1)
    }
}
