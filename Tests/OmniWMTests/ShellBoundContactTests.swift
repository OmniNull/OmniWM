// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import QuartzCore
import XCTest

@MainActor
final class ShellBoundContactTests: XCTestCase {
    private let helper = ShellManipulationSurfaceTests()
    private typealias Fixture = ShellManipulationSurfaceTests.Fixture

    private static let body = """
    local dy=ctx.data.dy or 0
    return ui.stack{w=600,h=400,
        ui.stack{key='desk',align='topLeading',dx=400,dy=80+dy,w=200,h=160,
            manipulationFollow={response=0.363,bounce=0.42},
            ui.box{key='grip',align='topLeading',w=200,h=20,onGesture=function() end,
                gesture={track={mode='move',target='desk',bounds={w=600,h=400},
                    min={w=200,h=160},max={w=200,h=160}}}}},
        ui.glass{key='bar',align='topLeading',w=600,h=400,backdrop=false,fill='#FFFFFFFF',rim=0,blend=0,
            ui.shape{key='desk-shape',align='topLeading',dx=-26,dy=-26,w=652,h=452,
                morph={source={target='desk',edge='right',from=14,span=50,
                    pads={left=-6.5,right=6.5,top=0,bottom=0},
                    adhere={left=14,top=14,bottom=14}},stops={{at=0},{at=1}}}},
            ui.shape{key='bulge',shape='ellipse',align='topLeading',dx=584,dy=130+dy,w=24,h=60,hit=false,
                morph={source={target='desk',edge='right',from=14,span=50,contact=true},stops={{at=0},{at=1}}}},
            ui.shape{key='crest',shape='ellipse',align='topLeading',dx=584,dy=151+dy,w=18,h=18,hit=false,
                reveal={response=1.04},morph={trigger={shape='bulge',at=0.7,rising=true,contact=true},
                    stops={{at=0,w=0},{at=0.5},{at=1,w=0}}}}}}
    """

    private func shifted(
        by translation: CGPoint = CGPoint(x: -50, y: 40), scale: CGFloat = 1
    ) throws -> (Fixture, CFTimeInterval) {
        let begin = CACurrentMediaTime()
        let fixture = try Fixture(Self.body, animations: true, clock: { begin })
        let target = try fixture.target()
        fixture.surface.scene.submit(fixture.surface.manipulationCommands(
            target, token: 1, presentation: .still(translation: translation, scale: scale, clip: nil),
            active: true
        ), animated: false)
        ShellLayerScene.engineQueue.sync {}
        return (fixture, begin)
    }

    func testBoundBodyInputCoverageLeavesTheTransparentCentreClear() throws {
        let begin = CACurrentMediaTime()
        let fixture = try Fixture(Self.body, animations: true, clock: { begin })
        let shape = try helper.shape(fixture, "desk-shape")
        let empty = CGPoint(x: 30, y: 30)
        let native = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[shape.slot]).shape(at: begin)
        }
        XCTAssertFalse(native.rect.contains(empty))
        XCTAssertFalse(fixture.surface.containsShape(at: empty))
        XCTAssertFalse(fixture.surface.islandRegions().contains { $0.contains(empty) })
    }

    func testBulgeContactCanMoveVerticallyWithTheDeskWithoutLuau() throws {
        let (fixture, time) = try shifted()
        let shape = try helper.shape(fixture, "bulge")
        let actual = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[shape.slot]).shape(at: time).rect
        }
        XCTAssertEqual(actual.midY, 200, accuracy: 0.01)
    }

    func testRippleCanCaptureTheDesksHeightAtTheBreakCrossing() throws {
        let (fixture, time) = try shifted()
        let shape = try helper.shape(fixture, "crest")
        try ShellLayerScene.engineQueue.sync {
            let entry = try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[shape.slot])
            XCTAssertEqual(entry.triggerPlans.first?.begin, time)
            XCTAssertEqual(entry.shape(at: time + 0.03).rect.midY, 200, accuracy: 0.01)
        }
    }

    func testPulseKeepsItsCapturedHeightAcrossFurtherTargetMotion() throws {
        let (fixture, time) = try shifted()
        let target = try fixture.target()
        let shape = try helper.shape(fixture, "crest")
        fixture.surface.scene.submit(fixture.surface.manipulationCommands(
            target, token: 2, presentation: .still(translation: CGPoint(x: -55, y: 80), scale: 1, clip: nil),
            active: true
        ), animated: false)
        ShellLayerScene.engineQueue.sync {}
        try ShellLayerScene.engineQueue.sync {
            let entry = try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[shape.slot])
            XCTAssertEqual(entry.triggerPlans.first?.contact?.position, 200)
            XCTAssertEqual(entry.shape(at: time + 0.03).rect.midY, 200, accuracy: 0.01)
        }
    }

    func testScaledDeskKeepsTheBulgeAndTheCapturedRippleOnItsPresentedCentre() throws {
        let (fixture, time) = try shifted(by: CGPoint(x: -30, y: 20), scale: 0.5)
        let presented = CGRect(x: 370, y: 100, width: 100, height: 80)
        let bulge = try helper.shape(fixture, "bulge")
        let crest = try helper.shape(fixture, "crest")
        try ShellLayerScene.engineQueue.sync {
            let placed = try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[bulge.slot]).shape(at: time).rect
            XCTAssertEqual(placed.midY, presented.midY, accuracy: 0.01)
            XCTAssertEqual(placed.midX, 596, accuracy: 0.01)
            XCTAssertEqual(placed.height, 60, accuracy: 0.01)
            let entry = try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[crest.slot])
            XCTAssertEqual(entry.triggerPlans.first?.begin, time)
            XCTAssertEqual(entry.triggerPlans.first?.contact?.position, presented.midY)
            XCTAssertEqual(entry.shape(at: time + 0.03).rect.midY, presented.midY, accuracy: 0.01)
        }
    }

    func testPulseKeepsTheCrossingPositionWhenTheAuthoredLayoutMoves() throws {
        let (fixture, time) = try shifted()
        var writer = ShellValueWriter()
        writer.number(40)
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(fixture.script.instance, "dy", $0.baseAddress, $0.count)
        }, OMNI_OK)
        fixture.render()
        let crest = try helper.shape(fixture, "crest")
        try ShellLayerScene.engineQueue.sync {
            let entry = try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[crest.slot])
            XCTAssertEqual(entry.triggerPlans.first?.contact?.position, 200)
            XCTAssertEqual(entry.shape(at: time + 0.03).rect.midY, 200, accuracy: 0.01)
        }
    }

    func testContactMovesOnlyTheTangentForEveryEdgeAndDoesNotScaleTheShape() {
        let shape = ShellGlassShape(
            slot: 1,
            kind: 1,
            rect: CGRect(x: 10, y: 20, width: 30, height: 40),
            radius: 0,
            thickness: 0
        )
        let input = ShellBoundInput(
            layout: CGRect(x: 100, y: 100, width: 200, height: 100),
            canvas: CGRect(x: 0, y: 0, width: 600, height: 400),
            presentation: .still(translation: CGPoint(x: -50, y: 40), scale: 0.5, clip: nil),
            active: false,
            time: 0
        )
        for edge in [ShellMorphRecipe.SourceEdge.top, .left, .right, .bottom] {
            let source = ShellMorphRecipe.Source(target: 1, edge: edge, from: 14, span: 50, pads: nil, contact: true)
            let result = ShellBoundGeometry.place(shape, source: source, input: input, progress: 0.5, at: 0)
            let vertical = edge == .left || edge == .right
            XCTAssertEqual(result.rect, shape.rect.offsetBy(dx: vertical ? 0 : -12.5, dy: vertical ? 70 : 0))
        }
    }
}
