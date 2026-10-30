// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class ShellVitreusMediaCardFrameBindingTests: XCTestCase {
    private let helper = ShellManipulationSurfaceTests()
    private static let body = """
    local vars=ctx.data.vars or {}
    local shapes={key='bar',w=600,h=400,backdrop=false,fill='#FFFFFFFF',rim=0,blend=0}
    if not vars.hidden then shapes[1]=ui.shape{key='card-glass',align='topLeading',w=600,h=400,radius=10,
        reveal={response=0.482,bounce=0.31},morph={source={target='card',edge='right',span=1,pads={}},
            stops={{at=0},{at=1}}}} end
    return ui.stack{w=600,h=400,ui.glass(shapes),
        ui.stack{key='card',align='topLeading',dx=vars.x or 80,dy=vars.y or 70,w=vars.w or 100,h=vars.h or 80,
            manipulationCommit=vars.commit,manipulationFollow={response=0.9,bounce=0.42},
            ui.box{key='grip',w=30,h=12,onGesture=function() end,
                gesture={track={mode='move',target='card',bounds={w=600,h=400},
                    min={w=50,h=40},max={w=200,h=160}}}}}}
    """

    func testRetainedFrameGlassKeepsTheLiveCardAcrossPinScaleRetargetAndCompletion() throws {
        let clock = ShellManipulationSurfaceTests.Clock()
        let fixture = try ShellManipulationSurfaceTests.Fixture(Self.body, animations: true) { clock.now }
        let target = try fixture.target()
        helper.setValues(
            fixture,
            numbers: ["x": 260, "y": 180, "w": 50, "h": 40],
            strings: ["commit": "pin"],
            flags: ["hidden": true]
        )
        fixture.render()
        let scene = fixture.surface.scene
        let retained = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(scene.shapeTracks.entries.first { $0.value.carrier != nil }).key
        }
        let end = try ShellLayerScene.engineQueue.sync { try XCTUnwrap(scene.shapeTracks.entries[retained]).end }
        func check(_ time: CFTimeInterval) throws {
            let motion = try XCTUnwrap(fixture.surface.follows[target]?.motion)
            let expected = motion.rect(at: time)
            let actual = try ShellLayerScene.engineQueue.sync {
                try XCTUnwrap(scene.shapeTracks.entries[retained]).shape(at: time)
            }
            XCTAssertEqual(actual.rect.midX, expected.midX, accuracy: 0.25)
            XCTAssertEqual(actual.rect.midY, expected.midY, accuracy: 0.25)
            XCTAssertEqual(actual.radius, 10 * expected.width / 100, accuracy: 0.01)
        }
        try check(clock.now + 0.08)
        clock.now += 0.04
        helper.setValues(
            fixture,
            numbers: ["x": 350, "y": 210, "w": 160, "h": 128],
            strings: ["commit": "retarget"],
            flags: ["hidden": true]
        )
        fixture.render()
        try check(clock.now + 0.06)
        try ShellLayerScene.engineQueue.sync {
            let entry = try XCTUnwrap(scene.shapeTracks.entries[retained])
            XCTAssertEqual(entry.end, end, accuracy: 1e-9)
            scene.completeShapeTrack(retained, generation: entry.generation)
            XCTAssertNil(scene.shapeTracks.entries[retained])
            XCTAssertNil(scene.glassShapes[retained])
            XCTAssertTrue(scene.shapeTracks.retainedBounds.isEmpty)
        }
    }

    func testRetainedFrameBindingIsDiscardedWithItsBodyOrSurface() throws {
        for reset in [false, true] {
            let fixture = try ShellManipulationSurfaceTests.Fixture(Self.body, animations: true)
            helper.setValues(fixture, numbers: ["x": 260], strings: ["commit": "pin"], flags: ["hidden": true])
            fixture.render()
            let scene = fixture.surface.scene
            ShellLayerScene.engineQueue.sync { XCTAssertFalse(scene.shapeTracks.retainedBounds.isEmpty) }
            if reset {
                fixture.surface.reset(text: fixture.text)
            } else {
                let body = try helper.shape(fixture, "bar")
                scene.submit([.remove(slot: body.slot)], animated: false)
            }
            ShellLayerScene.engineQueue.sync { XCTAssertTrue(scene.shapeTracks.retainedBounds.isEmpty) }
        }
    }
}
