// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellCursorTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let script: ShellScriptHostTests.Script
        let surface: ShellWidgetSurface
        let text = ShellTextStore()

        init(_ body: String) throws {
            script = try ShellScriptHostTests.Script("function render(ctx) " + body + " end")
            surface = ShellWidgetSurface(
                scale: 2,
                resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
                directories: []
            )
            render()
        }

        func render() {
            XCTAssertEqual(script.render().status, OMNI_OK, script.message)
            text.ingest(wire: script.output)
            XCTAssertTrue(surface.apply(script.output, text: text))
            surface.view.frame = CGRect(origin: .zero, size: surface.size)
        }
    }

    private func withSurface(_ body: String, check: (Fixture) throws -> Void) throws {
        let previous = NSCursor.current
        defer { previous.set() }
        try check(Fixture(body))
    }

    func testWireRoundTripPreservesBothCursorsAndOtherBehaviorFlags() throws {
        try withSurface("""
        return ui.stack{w=200,h=120,
            ui.box{w=20,h=20,cursor='grab'},ui.box{w=20,h=20,cursor='pointer'},
            ui.box{w=20,h=20,decorative=true},ui.glass{w=30,h=30,ui.shape{shape='ellipse',w=20,h=20}}}
        """) { fixture in
            let nodes = ShellScriptHostTests().decode(fixture.script.output)
            XCTAssertEqual(nodes.map(\.content.cursor), [.none, .grab, .pointer, .none, .none, .none])
            XCTAssertTrue(nodes[3].content.decorative)
            XCTAssertEqual(nodes[5].content.glassShape, 1)
            XCTAssertEqual(MemoryLayout<omni_wire_node>.stride, 448)
        }
    }

    func testInvalidCursorDeclarationsAreRejected() throws {
        for property in ["'arrow'", "'text'", "'closedHand'", "''", "true", "1", "{}"] {
            let script = try ShellScriptHostTests.Script("function render(ctx) return ui.box{cursor=\(property)} end")
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, property)
            XCTAssertTrue(script.message.contains("cursor"), script.message)
        }
    }

    func testDecorativeAndGlassTreesRejectCursors() throws {
        for tree in [
            "ui.box{decorative=true,cursor='grab'}",
            "ui.stack{decorative=true,ui.box{cursor='pointer'}}",
            "ui.glass{cursor='grab'}",
            "ui.glass{ui.shape{cursor='pointer'}}"
        ] {
            let script = try ShellScriptHostTests.Script("function render(ctx) return \(tree) end")
            XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME, tree)
            XCTAssertFalse(script.message.isEmpty)
        }
    }

    func testCursorOnlyZoneReceivesHoverAndRestoresArrowOnExit() throws {
        try withSurface("return ui.box{w=100,h=50,cursor='grab'}") { fixture in
            let surface = fixture.surface
            XCTAssertTrue(surface.hasAction(at: CGPoint(x: 20, y: 20)))
            XCTAssertTrue(surface.containsShape(at: CGPoint(x: 20, y: 20)))
            XCTAssertFalse(surface.containsShape(at: CGPoint(x: 120, y: 20)))
            XCTAssertTrue(surface.islandRegions().contains { $0.contains(CGPoint(x: 20, y: 20)) })
            surface.hover(at: CGPoint(x: 20, y: 20))
            XCTAssertTrue(surface.view.cursorState.current === NSCursor.openHand)
            XCTAssertTrue(NSCursor.current === NSCursor.openHand)
            surface.hover(at: nil)
            XCTAssertNil(surface.view.cursorState.current)
            XCTAssertTrue(NSCursor.current === NSCursor.arrow)
            XCTAssertFalse(surface.updateCursor())
        }
    }

    func testTopmostDeclaredCursorWinsAndUndeclaredOverlayDoesNotClaimIt() throws {
        try withSurface("""
        return ui.stack{w=200,h=120,
            ui.box{align='topLeading',w=100,h=80,cursor='grab'},
            ui.box{align='topLeading',w=50,h=40,cursor='pointer'},
            ui.box{align='topLeading',w=20,h=20},
            ui.box{decorative=true,w=200,h=120}}
        """) { fixture in
            let surface = fixture.surface
            surface.hover(at: CGPoint(x: 10, y: 10))
            XCTAssertTrue(surface.view.cursorState.current === NSCursor.pointingHand)
            surface.hover(at: CGPoint(x: 70, y: 60))
            XCTAssertTrue(surface.view.cursorState.current === NSCursor.openHand)
            surface.hover(at: CGPoint(x: 180, y: 100))
            XCTAssertNil(surface.view.cursorState.current)
            XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        }
    }

    func testRepeatedSamplesDoNotSetTheNativeCursorAgain() throws {
        try withSurface("return ui.box{w=100,h=50,cursor='pointer'}") { fixture in
            let surface = fixture.surface
            surface.pointer = CGPoint(x: 10, y: 10)
            XCTAssertTrue(surface.updateCursor())
            for index in 0 ..< 20 {
                surface.hover(at: CGPoint(x: 20 + index, y: 10))
                XCTAssertFalse(surface.updateCursor())
            }
            XCTAssertTrue(surface.view.cursorState.current === NSCursor.pointingHand)
        }
    }

    func testUndeclaredElementsNeverClaimTheCursor() throws {
        try withSurface("return ui.box{w=100,h=50,onClick=function() end}") { fixture in
            NSCursor.crosshair.set()
            fixture.surface.hover(at: CGPoint(x: 10, y: 10))
            XCTAssertNil(fixture.surface.view.cursorState.current)
            XCTAssertTrue(NSCursor.current === NSCursor.crosshair)
            fixture.surface.hover(at: nil)
            XCTAssertTrue(NSCursor.current === NSCursor.crosshair)
            XCTAssertFalse(fixture.surface.updateCursor())
        }
    }

    func testManipulationCursorOverridesHoverAndRestoresTheReleaseZone() throws {
        try withSurface("""
        return ui.row{w=200,h=50,ui.box{w=100,h=50,cursor='grab'},ui.box{w=100,h=50,cursor='pointer'}}
        """) { fixture in
            let surface = fixture.surface
            surface.hover(at: CGPoint(x: 20, y: 20))
            XCTAssertTrue(surface.setManipulationCursor(true, at: CGPoint(x: 20, y: 20)))
            XCTAssertTrue(surface.view.cursorState.current === NSCursor.closedHand)
            XCTAssertFalse(surface.setManipulationCursor(true, at: CGPoint(x: 120, y: 20)))
            surface.hover(at: nil)
            XCTAssertTrue(surface.view.cursorState.current === NSCursor.closedHand)
            XCTAssertTrue(surface.setManipulationCursor(false, at: CGPoint(x: 120, y: 20)))
            XCTAssertTrue(surface.view.cursorState.current === NSCursor.pointingHand)
            XCTAssertFalse(surface.setManipulationCursor(false, at: CGPoint(x: 120, y: 20)))
            XCTAssertTrue(surface.setManipulationCursor(true, at: CGPoint(x: 120, y: 20)))
            XCTAssertTrue(surface.setManipulationCursor(false, at: nil))
            XCTAssertNil(surface.view.cursorState.current)
            XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        }
    }

    func testKeyedCursorChangesAndRemovalRefreshWithoutPointerMovement() throws {
        try withSurface("""
        local step=ctx.data.cpu
        return ui.stack{w=200,h=120,
            ui.box{key='zone',w=100,h=50,cursor=step==0 and 'grab' or step==1 and 'pointer' or nil}}
        """) { fixture in
            let surface = fixture.surface
            XCTAssertEqual(omni_instance_set_number(fixture.script.instance, "cpu", 0), OMNI_OK)
            fixture.render()
            surface.hover(at: CGPoint(x: 50, y: 50))
            let handle = surface.element(at: surface.pointer) { $0.cursor != .none }
            XCTAssertTrue(surface.view.cursorState.current === NSCursor.openHand)
            XCTAssertEqual(omni_instance_set_number(fixture.script.instance, "cpu", 1), OMNI_OK)
            fixture.render()
            XCTAssertEqual(surface.element(at: surface.pointer) { $0.cursor != .none }, handle)
            XCTAssertTrue(surface.view.cursorState.current === NSCursor.pointingHand)
            XCTAssertEqual(omni_instance_set_number(fixture.script.instance, "cpu", 2), OMNI_OK)
            fixture.render()
            XCTAssertTrue(surface.layout.core.contains(handle))
            XCTAssertNil(surface.view.cursorState.current)
            XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        }
    }

    func testCursorHitTestingRespectsAncestorBounds() throws {
        try withSurface("""
        return ui.stack{w=200,h=120,
            ui.stack{align='topLeading',dx=20,dy=20,w=40,h=40,
                ui.box{align='topLeading',w=100,h=100,cursor='grab'}}}
        """) { fixture in
            fixture.surface.hover(at: CGPoint(x: 30, y: 30))
            XCTAssertTrue(fixture.surface.view.cursorState.current === NSCursor.openHand)
            fixture.surface.hover(at: CGPoint(x: 80, y: 30))
            XCTAssertNil(fixture.surface.view.cursorState.current)
            XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        }
    }

    func testSurfaceTrackingOwnsCursorUpdatesAndMouseExit() throws {
        try withSurface("return ui.box{w=100,h=50,cursor='grab'}") { fixture in
            let view = fixture.surface.view
            XCTAssertTrue(view.trackingAreas.contains { $0.options.contains(.cursorUpdate) })
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .mouseMoved, location: CGPoint(x: 20, y: 20), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            ))
            view.cursorUpdate(with: event)
            XCTAssertTrue(view.cursorState.current === NSCursor.openHand)
            view.mouseExited(with: event)
            XCTAssertNil(view.cursorState.current)
            XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        }
    }
}
