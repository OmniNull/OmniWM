// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
enum ShellBoundSurfaceFixture {
    typealias Fixture = ShellManipulationSurfaceTests.Fixture
    typealias Clock = ShellManipulationSurfaceTests.Clock

    static let body = """
    ctx.state.renders=(ctx.state.renders or 0)+1
    local vars=ctx.data.vars or {}
    local target={key='widget',align='topLeading',dx=411,dy=70,w=200,h=160,
        manipulationFollow={response=0.363,bounce=0.42},
        ui.box{key='move',align='topLeading',w=200,h=20,onGesture=function() end,
            gesture={track={mode='move',target='widget',bounds={w=730,h=400},
                min={w=80,h=64},max={w=200,h=160}}}},
        ui.box{key='scale',align='bottomTrailing',w=12,h=12,onGesture=function() end,
            gesture={track={mode='scale',target='widget',edge='se',bounds={w=730,h=400},
                min={w=80,h=64},max={w=200,h=160}}}}}
    return ui.stack{key='root',w=730,h=400,
        if vars.replace then ui.box(target) else ui.stack(target),
        ui.glass{key='panes',align='topLeading',dx=vars.bodyX or 0,w=700,h=400,
            backdrop=false,fill='#FFFFFFFF',shadow='#00000000',rim=0,blend=0,
            ui.shape{key='bound',align='topLeading',dx=400,dy=70,w=226,h=160,radius=0,hit=false,
                morph={source={target='widget',edge='right',from=114,span=50,
                    pads={left=-13,right=13,top=-13,bottom=13}},stops={{at=0},{at=1}}}}},
        ui.text{key='render-count',align='topLeading',dx=-10000,text=tostring(ctx.state.renders)}}
    """

    static func stage(_ fixture: Fixture, at begin: CFTimeInterval) throws -> ShellGlassSceneTests
        .FollowStage
    {
        try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            let root = scene.container
            root.removeFromSuperlayer()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.frame = CGRect(x: 0, y: 0, width: 730, height: 400)
            root.isGeometryFlipped = true
            root.speed = 0
            root.timeOffset = begin
            CATransaction.commit()
            let renderer = try ShellOffscreenRenderer(root: root, width: 730, height: 400)
            _ = try renderer.render(paused: begin)
            return .init(scene: scene, renderer: renderer, width: 730, height: 400)
        }
    }

    static func element(_ fixture: Fixture, _ name: String) throws -> ElementHandle {
        try ShellManipulationSurfaceTests().shape(fixture, name)
    }

    static func scale(_ fixture: Fixture, to factor: Double, timestamp: Double = 0.01) throws {
        let surface = fixture.surface
        if surface.manipulation == nil {
            surface.press(at: CGPoint(x: 605, y: 224), timestamp: 0)
        }
        surface.drag(
            to: CGPoint(x: 605 - 200 * (1 - factor), y: 224 - 160 * (1 - factor)),
            screen: .zero,
            timestamp: timestamp
        )
        ShellLayerScene.engineQueue.sync {}
        let preview = try XCTUnwrap(surface.manipulation?.preview)
        XCTAssertEqual(preview.width, 200 * factor, accuracy: 1e-9)
        XCTAssertEqual(preview.height, 160 * factor, accuracy: 1e-9)
    }

    static func renderCount(_ fixture: Fixture) throws -> String {
        let handle = try element(fixture, "render-count")
        return fixture.text.string(fixture.surface.layout.core.content(of: handle).text)
    }

    static func expected(_ fixture: Fixture) throws -> CGRect {
        let surface = fixture.surface
        let target = try fixture.target()
        let raw = try CGRect(surface.layout.core.absoluteFrame(of: element(fixture, "bound")))
        let canvas = try CGRect(surface.layout.core.absoluteFrame(of: element(fixture, "panes")))
        let layout = CGRect(surface.layout.core.absoluteFrame(of: target))
        let shown = CGRect(surface.presentedFrame(of: target))
        let scale = shown.width / layout.width
        let progress = min(max((canvas.maxX - shown.maxX - 114) / 50, 0), 1)
        let left = shown.minX - 13 * scale
        let right = raw.maxX + (shown.maxX + 13 * scale - raw.maxX) * progress
        let top = shown.minY - 13 * scale
        let bottom = shown.maxY + 13 * scale
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func assertRect(
        _ actual: CGRect,
        _ expected: CGRect,
        accuracy: Double = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.maxX, expected.maxX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.maxY, expected.maxY, accuracy: accuracy, file: file, line: line)
    }
}

@MainActor
final class ShellBoundTrackSurfaceTests: XCTestCase {
    private typealias Fixture = ShellBoundSurfaceFixture

    func testBoundPointerSamplesDoNotPublishLuauOrMutateTheAuthoredShapeFrame() throws {
        let fixture = try Fixture.Fixture(Fixture.body, animations: false)
        let shape = try Fixture.element(fixture, "bound")
        let local = fixture.surface.layout.core.layoutFrame(of: shape)
        let wire = fixture.script.output
        XCTAssertEqual(try Fixture.renderCount(fixture), "1")
        XCTAssertEqual(fixture.surface.layout.core.content(of: shape).glassFollow, 0)
        for (index, factor) in [0.9, 0.8, 0.7, 0.85].enumerated() {
            try Fixture.scale(fixture, to: factor, timestamp: Double(index + 1) * 0.01)
            XCTAssertEqual(fixture.script.output, wire)
            XCTAssertEqual(try Fixture.renderCount(fixture), "1")
            XCTAssertEqual(fixture.surface.layout.core.layoutFrame(of: shape), local)
            XCTAssertEqual(fixture.events.filter { $0.event.phase == .began }.count, 1)
            XCTAssertFalse(fixture.events.contains { $0.event.phase == .changed })
        }
        fixture.surface.cancelInput()
        fixture.render()
        XCTAssertEqual(try Fixture.renderCount(fixture), "2")
    }

    func testDroppingABoundStartsTheGlassFromWhereItWasDrawn() throws {
        let body = """
        local vars=ctx.data.vars or {}
        local h=vars.h or 160
        return ui.stack{key='root',w=730,h=400,
            ui.stack{key='widget',align='topLeading',dx=100,dy=70,w=200,h=h,animate={response=0.5,bounce=0},
                manipulationFollow={response=0.363,bounce=0.42},
                ui.box{key='move',align='topLeading',w=200,h=20,onGesture=function() end,
                    gesture={track={mode='move',target='widget',bounds={w=730,h=400},
                        min={w=80,h=64},max={w=200,h=400}}}}},
            ui.glass{key='panes',align='topLeading',w=700,h=400,
                backdrop=false,fill='#FFFFFFFF',shadow='#00000000',rim=0,blend=0,
                if vars.docked then ui.shape{key='bound',align='topLeading',follow='widget',
                    dx=100,dy=70,w=200,h=h,radius=0,hit=false}
                else ui.shape{key='bound',align='topLeading',dx=-26,dy=-26,w=782,h=452,radius=0,hit=false,
                    morph={source={target='widget',edge='right',from=114,span=50,
                        pads={left=-13,right=13,top=-13,bottom=13}},stops={{at=0},{at=1}}}}}}
        """
        let fixture = try Fixture.Fixture(body, animations: true)
        let shape = try Fixture.element(fixture, "bound")
        let scene = fixture.surface.scene
        let drawn = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(scene.shapeTracks.entries[shape.slot]).shape(at: CACurrentMediaTime()).rect
        }
        XCTAssertLessThan(drawn.width, 300)
        ShellManipulationSurfaceTests().setValues(fixture, numbers: ["h": 220], flags: ["docked": true])
        fixture.render()
        let base = try ShellLayerScene.engineQueue.sync { try XCTUnwrap(scene.shapeTracks.entries[shape.slot]).base }
        XCTAssertGreaterThan(base.duration, 0)
        Fixture.assertRect(base.state(at: base.begin).shape.rect, drawn)
    }
}
