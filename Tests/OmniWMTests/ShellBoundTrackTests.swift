// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import QuartzCore
import XCTest

@MainActor
final class ShellBoundTrackTests: XCTestCase {
    typealias Fixture = ShellManipulationSurfaceTests.Fixture
    let helper = ShellManipulationSurfaceTests()

    static let pulseBody = """
    return ui.stack{key='root',w=730,h=400,
        ui.stack{key='widget',align='topLeading',dx=386,dy=70,w=200,h=160,
            manipulationFollow={response=0.363,bounce=0.42},
            ui.box{w=200,h=20,onGesture=function() end,
                gesture={track={mode='move',target='widget',bounds={w=730,h=400},
                    min={w=80,h=64},max={w=200,h=160}}}}},
        ui.glass{key='panes',w=700,h=400,align='topLeading',backdrop=false,
            fill='#FFFFFFFF',shadow='#00000000',rim=0,blend=0,
            ui.shape{key='bound',dx=400,dy=70,align='topLeading',w=226,h=160,hit=false,
                morph={source={target='widget',edge='right',from=114,span=50},stops={{at=0},{at=1}},
                    impulses={{at=0.7,rising=true,spring={response=0.12},velocity=-280,w=1},
                        {at=0.7,rising=false,spring={response=0.12},velocity=80,w=1}}}},
            ui.shape{key='up',dx=80,dy=260,align='topLeading',w=60,h=30,hit=false,
                reveal={response=0.12},morph={trigger={shape='bound',at=0.7,rising=true},
                    stops={{at=0,w=0,h=0},{at=0.5},{at=1,w=0,h=0}}}},
            ui.shape{key='down',dx=180,dy=260,align='topLeading',w=60,h=30,hit=false,
                reveal={response=0.12},morph={trigger={shape='bound',at=0.7,rising=false},
                    stops={{at=0,w=0,h=0},{at=0.5},{at=1,w=0,h=0}}}}}}
    """

    func send(_ input: ShellBoundInput, to shape: Int32, on fixture: Fixture) {
        fixture.surface.scene.submit([.boundTrack(slot: shape, input)], animated: false)
        ShellLayerScene.engineQueue.sync {}
    }

    func input(
        at begin: CFTimeInterval, active: Bool = false,
        spring: ShellSpringDynamics.Parameters = ShellMorphRecipe.Spring(response: 0.363, bounce: 0.42).parameters
    ) throws -> ShellBoundInput {
        let layout = CGRect(x: 386, y: 70, width: 200, height: 160)
        let motion = try XCTUnwrap(ShellManipulationMotion(
            from: layout, to: layout.offsetBy(dx: -32.5, dy: 0), begin: begin, spring: spring
        ))
        return ShellBoundInput(
            layout: layout,
            canvas: CGRect(x: 0, y: 0, width: 700, height: 400),
            presentation: .motion(motion.wrapper(for: layout)),
            active: active,
            time: begin
        )
    }

    func testSourceAndFollowCannotOwnTheSameShape() throws {
        let script = try ShellScriptHostTests.Script("function render(ctx) " + Self.pulseBody.replacingOccurrences(
            of: "key='bound',", with: "key='bound',follow='widget',"
        ) + " end")
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertTrue(script.message.contains("cannot be combined"), script.message)
    }

    func testBoundBulgeAtPointFortyTwoMatchesTheVitreusBell() throws {
        let source = ShellMorphRecipe.Source(target: 1, edge: .right, from: 14, span: 50, pads: nil)
        let input = ShellBoundInput(
            layout: CGRect(x: 0, y: 0, width: 565, height: 100),
            canvas: CGRect(x: 0, y: 0, width: 600, height: 400),
            presentation: .identity,
            active: false,
            time: 0
        )
        let bound = ShellBoundTrack(input: input, source: source, previous: nil, revision: 1)
        let stops = (0 ... 15).map { index in
            let progress = Double(index) / 15
            let width = max(0.3 / 24, 4 * progress * (1 - progress) * (1 - 0.5 * progress))
            return "\(progress),1,1,\(width),1,1"
        }.joined(separator: ";")
        let morph = try XCTUnwrap(ShellMorphRecipe("morph:0.5:0.5:0:0:0:0:" + stops))
        let raw = ShellGlassShape(
            slot: 1,
            kind: 1,
            rect: CGRect(x: 500, y: 100, width: 24, height: 8),
            radius: 0,
            thickness: 0
        )
        var entry = ShellShapeTrackEntry(
            body: 0,
            identity: nil,
            base: ShellShapeBaseMotion(from: raw, to: raw, begin: 0),
            morph: morph,
            begin: 0
        )
        entry.bound = bound
        XCTAssertEqual(bound.state(at: 0).progress, 0.42, accuracy: 1e-12)
        XCTAssertEqual(entry.shape(at: 0).rect.width, 18.5, accuracy: 0.2)
    }
}
