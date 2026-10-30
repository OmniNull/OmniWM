// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
extension ShellRevealTests {
    private static let layoutJumpBody = """
    local open=ctx.data.open
    return ui.stack{w=400,h=300,
        ui.box{decorative=true,w=400,h=300,fill='surface'},
        open and ui.glass{key='sheetglass',blend=0,fill='#FFFFFFFF',blurRadius=0,shadow='#00000000',
            shadowRadius=0,saturation=1,
            ui.shape{key='sheet',radius=16,reveal={response=0.482,bounce=0.31},
                morph={anchor={x=0.5,y=0},stops={{at=0,scale=0.05},{at=1,scale=1}}}}} or nil,
        open and ui.stack{key='desk',reveal={response=0.482,bounce=0.31},align='topLeading',dx=100,dy=50,w=200,h=200,
            ui.glass{key='glass',w=200,h=200,blend=0,fill='#FFFFFFFF',blurRadius=0,shadow='#00000000',
                shadowRadius=0,saturation=1,
                ui.shape{key='card',w=200,h=200,radius=16,reveal={response=0.482,bounce=0.31},
                    morph={anchor={x=1,y=0.5},stops={{at=0,scale=0.05},{at=1,scale=1}}}}},
            ui.stack{key='content',w=200,h=200,morph={anchor={x=1,y=0.5},stops={
                {at=0,scale=0.05,opacity=0},{at=1}}},
                ui.box{key='button',align='topLeading',dx=140,dy=80,w=40,h=40,fill='accent',
                    onClick=function() end}}} or nil}
    """

    private struct LayoutJumpHandles {
        let sheet: ElementHandle
        let desk: ElementHandle
        let card: ElementHandle
        let content: ElementHandle
    }

    private struct LayoutJumpDesk {
        let fixture: Fixture
        let clock: Clock
        let renderer: ShellOffscreenRenderer
        let handles: LayoutJumpHandles
    }

    private func layoutJumpOpen() throws -> LayoutJumpDesk {
        let clock = Clock()
        let fixture = try Fixture(Self.layoutJumpBody, animations: true) { clock.now }
        let container = fixture.surface.scene.container
        let renderer = try ShellLayerScene.engineQueue.sync {
            container.removeFromSuperlayer()
            return try ShellOffscreenRenderer(root: container, width: 400, height: 300)
        }
        var writer = ShellValueWriter()
        writer.bool(true)
        _ = writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(fixture.script.instance, "open", $0.baseAddress, $0.count)
        }
        fixture.render()
        func keyed(_ name: String) throws -> ElementHandle {
            let key = name.utf8.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
                & ~(UInt64(3) << 62)
            let layout = fixture.surface.layout
            return try XCTUnwrap(layout.core.elements { _ in true }.first { layout.core.key(of: $0) == key })
        }
        let handles = try LayoutJumpHandles(
            sheet: keyed("sheet"), desk: keyed("desk"), card: keyed("card"), content: keyed("content")
        )
        return LayoutJumpDesk(fixture: fixture, clock: clock, renderer: renderer, handles: handles)
    }

    private func layoutJumpDrain() async {
        ShellLayerScene.engineQueue.sync {}
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func layoutJumpTrackRuns(_ fixture: Fixture, _ shape: ElementHandle, _ message: String) throws {
        XCTAssertNotNil(fixture.surface.reveals[shape]?.plan, message)
        try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            XCTAssertNotNil(scene.presence.revealPlans[shape.slot], message)
            let entry = try XCTUnwrap(scene.shapeTracks.entries[shape.slot], message)
            XCTAssertNotNil(entry.plan, message)
            XCTAssertFalse(entry.animations.isEmpty, message)
            let layers = try XCTUnwrap(scene.glassBodies[entry.body]).lockstepLayers(shape.slot)
            XCTAssertFalse(layers.isEmpty, message)
            for layer in layers {
                XCTAssertNotNil(layer.animation(forKey: "omni.glass.position"), message)
            }
        }
    }

    private func layoutJumpTrackEnded(
        _ fixture: Fixture, _ shape: ElementHandle, rect: CGRect?, _ message: String
    ) throws {
        XCTAssertNil(fixture.surface.reveals[shape]?.plan, message)
        try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            XCTAssertNil(scene.presence.revealPlans[shape.slot], message)
            let entry = try XCTUnwrap(scene.shapeTracks.entries[shape.slot], message)
            XCTAssertNil(entry.plan, message)
            XCTAssertTrue(entry.animations.isEmpty, message)
            if let rect { XCTAssertEqual(entry.terminal.rect, rect, message) }
            for layer in try XCTUnwrap(scene.glassBodies[entry.body]).lockstepLayers(shape.slot) {
                XCTAssertNil(layer.animation(forKey: "omni.glass.position"), message)
            }
        }
    }

    private func layoutJumpDeskRuns(_ fixture: Fixture, _ handles: LayoutJumpHandles, _ message: String) throws {
        XCTAssertNotNil(fixture.surface.reveals[handles.desk]?.plan, message)
        ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            XCTAssertNotNil(scene.presence.revealPlans[handles.desk.slot], message)
            XCTAssertNotNil(
                scene.presentedContent(handles.content.slot)?.animation(forKey: ShellLayerScene.revealTransformKey),
                message
            )
        }
        try layoutJumpTrackRuns(fixture, handles.card, message)
    }

    func testRootBleedEndsTheStretchedShapeRevealAndKeepsTheDeskRunning() async throws {
        let opened = try layoutJumpOpen()
        let fixture = opened.fixture
        let clock = opened.clock
        let renderer = opened.renderer
        let handles = opened.handles
        defer { withExtendedLifetime(renderer) {} }
        try layoutJumpTrackRuns(fixture, handles.sheet, "sheet opened")
        try layoutJumpDeskRuns(fixture, handles, "desk opened")
        clock.now += 0.05
        fixture.surface.setRootBleed(Insets(top: 8))
        await layoutJumpDrain()
        try layoutJumpTrackEnded(
            fixture,
            handles.sheet,
            rect: CGRect(x: 0, y: 0, width: 400, height: 308),
            "bled sheet"
        )
        try layoutJumpDeskRuns(fixture, handles, "desk after bleed")
    }

    func testRootLimitEndsTheResizedShapeRevealAndKeepsTheDeskRunning() async throws {
        let opened = try layoutJumpOpen()
        let fixture = opened.fixture
        let clock = opened.clock
        let renderer = opened.renderer
        let handles = opened.handles
        defer { withExtendedLifetime(renderer) {} }
        clock.now += 0.05
        fixture.surface.setRootLimit(CGSize(width: 360, height: 260))
        await layoutJumpDrain()
        try layoutJumpTrackEnded(
            fixture,
            handles.sheet,
            rect: CGRect(x: 0, y: 0, width: 360, height: 260),
            "limited sheet"
        )
        try layoutJumpDeskRuns(fixture, handles, "desk after limit")
    }

    func testMotionOffEndsEveryRevealAndTrackOnTheNextRender() async throws {
        let opened = try layoutJumpOpen()
        let fixture = opened.fixture
        let clock = opened.clock
        let renderer = opened.renderer
        let handles = opened.handles
        defer { withExtendedLifetime(renderer) {} }
        clock.now += 0.05
        fixture.surface.motionPolicy.userAnimationsEnabled = false
        fixture.render()
        await layoutJumpDrain()
        try layoutJumpTrackEnded(fixture, handles.sheet, rect: nil, "sheet motion off")
        try layoutJumpTrackEnded(fixture, handles.card, rect: nil, "card motion off")
        XCTAssertNil(fixture.surface.reveals[handles.desk]?.plan)
        ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            XCTAssertTrue(scene.presence.revealPlans.isEmpty)
            XCTAssertNil(
                scene.presentedContent(handles.content.slot)?.animation(forKey: ShellLayerScene.revealTransformKey)
            )
        }
    }
}
