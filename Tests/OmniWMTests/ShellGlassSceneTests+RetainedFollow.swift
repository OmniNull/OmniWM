// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

extension ShellGlassSceneTests {
    private static let retainedFollowBody = """
    local vars=ctx.data.vars or {}
    local drip={response=0.482,bounce=0.31}
    local morph={anchor={x=0.5,y=0.5},stops={{at=0,scale=0},{at=1,scale=1}}}
    return ui.stack{key='root',w=600,h=400,
        ui.glass{key='panes',align='topLeading',w=600,h=400,
            backdrop=false,fill='#FFFFFFFF',shadow='#00000000',rim=0,blend=0,
            not vars.hidden and ui.shape{key='card-glass',align='topLeading',dx=80,dy=70,w=100,h=80,
                radius=0,follow='card',reveal=drip,morph=morph} or nil},
        not vars.removed and ui.stack{key='card',align='topLeading',dx=vars.x or 80,dy=vars.y or 70,
            w=vars.w or 100,h=vars.h or 80,manipulationCommit=vars.commit,
            manipulationFollow={response=0.9,bounce=0.42},
            exit={dx=-40,dy=20,scale=0.6,anchor={x=0,y=0},animate='ease'},
            ui.box{key='grip',align='topLeading',w=50,h=12,onGesture=function() end,
                gesture={track={mode='move',target='card',bounds={w=600,h=400},
                    min={w=50,h=40},max={w=200,h=160}}}},
            ui.box{key='content',w=vars.w or 100,h=vars.h or 80,fill='#FFFFFFFF'}} or nil}
    """

    private struct RetainedFollower {
        let fixture: ShellManipulationSurfaceTests.Fixture
        let clock: ShellManipulationSurfaceTests.Clock
        let target: ElementHandle
        let slot: Int32
        let begin: CFTimeInterval
    }

    private func retiringFollower() throws -> RetainedFollower {
        let helper = ShellManipulationSurfaceTests()
        let clock = ShellManipulationSurfaceTests.Clock()
        let fixture = try ShellManipulationSurfaceTests.Fixture(Self.retainedFollowBody, animations: true) { clock.now }
        let target = try fixture.target()
        let logical = try helper.shape(fixture, "card-glass")
        helper.setValues(
            fixture,
            numbers: ["x": 260, "y": 180, "w": 50, "h": 40],
            strings: ["commit": "dock"],
            flags: ["hidden": true]
        )
        fixture.render()
        XCTAssertTrue(fixture.surface.layout.core.contains(target))
        XCTAssertFalse(fixture.surface.layout.core.contains(logical))
        XCTAssertNotNil(fixture.surface.follows[target]?.motion)
        return try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            let retained = try XCTUnwrap(scene.shapeTracks.entries.first { $0.value.carrier != nil })
            XCTAssertNotEqual(retained.key, logical.slot)
            XCTAssertNotNil(scene.shapeTracks.follows[retained.key])
            XCTAssertEqual(retained.value.plan?.target, 0)
            XCTAssertEqual(retained.value.plan?.commit, clock.now)
            return RetainedFollower(
                fixture: fixture,
                clock: clock,
                target: target,
                slot: retained.key,
                begin: clock.now
            )
        }
    }

    private func retainedRect(_ state: RetainedFollower, at time: CFTimeInterval) throws -> CGRect {
        try ShellLayerScene.engineQueue.sync {
            let scene = state.fixture.surface.scene
            let entry = try XCTUnwrap(scene.shapeTracks.entries[state.slot])
            let plan = scene.trackPlan(entry, slot: state.slot)
            let elapsed = time - plan.begin
            let last = try XCTUnwrap(plan.samples.last)
            guard let index = plan.samples.firstIndex(where: { $0.time >= elapsed }) else { return last.shape.rect }
            let right = plan.samples[index]
            guard index > 0 else { return right.shape.rect }
            let left = plan.samples[index - 1]
            let fraction = (elapsed - left.time) / (right.time - left.time)
            let first = ShellShapeBaseMotion.vector(left.shape)
            let value = first + (ShellShapeBaseMotion.vector(right.shape) - first) * fraction
            return CGRect(x: value[0], y: value[1], width: value[2], height: value[3])
        }
    }

    private func assertRetainedFollower(
        _ state: RetainedFollower,
        at time: CFTimeInterval,
        line: UInt = #line
    ) throws {
        let surface = state.fixture.surface
        let motion = surface.follows[state.target]?.motion
        let expected = motion?.rect(at: time) ?? CGRect(surface.layout.core.absoluteFrame(of: state.target))
        let progress = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(surface.scene.shapeTracks.entries[state.slot]?.plan).state(at: time).progress
        }
        XCTAssertGreaterThan(progress, 0.1, line: line)
        let rect = try retainedRect(state, at: time)
        print("RETAINED-FOLLOW", time - state.begin, "glass", rect, "target", expected, "progress", progress)
        let scale = surface.scene.scale
        XCTAssertEqual(rect.midX * scale, expected.midX * scale, accuracy: 0.5, line: line)
        XCTAssertEqual(rect.midY * scale, expected.midY * scale, accuracy: 0.5, line: line)
        XCTAssertEqual(rect.width * scale, expected.width * progress * scale, accuracy: 0.5, line: line)
        XCTAssertEqual(rect.height * scale, expected.height * progress * scale, accuracy: 0.5, line: line)
    }

    func testRetainedFollowerKeepsTheLiveTargetsPlacementSpringUntilItsOwnExitCompletes() throws {
        let state = try retiringFollower()
        for elapsed in [0.04, 0.08, 0.12] {
            try assertRetainedFollower(state, at: state.begin + elapsed)
        }
        let scene = state.fixture.surface.scene
        let motion = try XCTUnwrap(state.fixture.surface.follows[state.target]?.motion)
        let completion = try ShellLayerScene.engineQueue.sync {
            let entry = try XCTUnwrap(scene.shapeTracks.entries[state.slot])
            let plan = scene.trackPlan(entry, slot: state.slot)
            XCTAssertEqual(plan.begin + plan.duration, entry.end, accuracy: 1e-9)
            XCTAssertLessThan(entry.end, motion.begin + motion.duration)
            let animation = try XCTUnwrap(entry.animations.first?.animation)
            return try (XCTUnwrap(animation.delegate as? ShellManipulationCompletion), animation)
        }
        completion.0.animationDidStop(completion.1, finished: true)
        ShellLayerScene.engineQueue.sync {}
        ShellLayerScene.engineQueue.sync {
            XCTAssertNil(scene.shapeTracks.entries[state.slot])
            XCTAssertNil(scene.shapeTracks.follows[state.slot])
            XCTAssertNil(scene.glassShapes[state.slot])
            XCTAssertFalse(scene.shapeTracks.retired.values.contains(state.slot))
            XCTAssertTrue(scene.shapeTracks.retainedFollowers.isEmpty)
        }
        XCTAssertTrue(state.fixture.surface.layout.core.contains(state.target))
    }

    func testRetainedFollowerAcceptsLaterScaleRetargetAndIdentityWithoutRestartingItsExit() throws {
        let state = try retiringFollower()
        let helper = ShellManipulationSurfaceTests()
        state.clock.now = state.begin + 0.04
        helper.setValues(
            state.fixture,
            numbers: ["x": 350, "y": 210, "w": 160, "h": 128],
            strings: ["commit": "retarget"],
            flags: ["hidden": true]
        )
        state.fixture.render()
        for elapsed in [0.05, 0.09, 0.13] {
            try assertRetainedFollower(state, at: state.begin + elapsed)
        }
        state.clock.now = state.begin + 0.14
        state.fixture.surface.finishSettle()
        ShellLayerScene.engineQueue.sync {}
        XCTAssertNil(state.fixture.surface.follows[state.target]?.motion)
        try assertRetainedFollower(state, at: state.begin + 0.14)
        try ShellLayerScene.engineQueue.sync {
            let entry = try XCTUnwrap(state.fixture.surface.scene.shapeTracks.entries[state.slot])
            XCTAssertEqual(entry.plan?.commit, state.begin)
        }
    }

    func testRetainedFollowerAssociationEndsOnBodyForgetAndSurfaceReset() throws {
        for reset in [false, true] {
            let state = try retiringFollower()
            let scene = state.fixture.surface.scene
            ShellLayerScene.engineQueue.sync {
                XCTAssertEqual(scene.shapeTracks.retainedFollowers[state.target.slot], [state.slot])
            }
            if reset {
                state.fixture.surface.reset(text: ShellTextStore())
            } else {
                let body = try ShellManipulationSurfaceTests().shape(state.fixture, "panes")
                scene.submit([.remove(slot: body.slot)], animated: false)
            }
            ShellLayerScene.engineQueue.sync {}
            ShellLayerScene.engineQueue.sync {
                XCTAssertNil(scene.shapeTracks.entries[state.slot])
                XCTAssertNil(scene.shapeTracks.follows[state.slot])
                XCTAssertNil(scene.glassShapes[state.slot])
                XCTAssertTrue(scene.shapeTracks.retainedFollowers.isEmpty)
                XCTAssertFalse(scene.shapeTracks.retired.values.contains(state.slot))
            }
        }
    }

    func testRetainedFollowerComposesALaterTargetExitAgainstItsOriginalScaleBasis() throws {
        let state = try retiringFollower()
        let surface = state.fixture.surface
        let outer = try XCTUnwrap(surface.follows[state.target]?.motion)
        let targetLayout = CGRect(surface.layout.core.absoluteFrame(of: state.target))
        XCTAssertEqual(targetLayout.width, 50)
        state.clock.now = state.begin + 0.04
        ShellManipulationSurfaceTests().setValues(
            state.fixture,
            numbers: ["x": 260, "y": 180, "w": 50, "h": 40],
            strings: ["commit": "dock"],
            flags: ["hidden": true, "removed": true]
        )
        state.fixture.render()
        XCTAssertFalse(surface.layout.core.contains(state.target))
        let departure = try ShellLayerScene.engineQueue.sync {
            let follow = try XCTUnwrap(surface.scene.shapeTracks.follows[state.slot])
            XCTAssertNil(follow.binding)
            XCTAssertTrue(surface.scene.shapeTracks.retainedFollowers.isEmpty)
            return try XCTUnwrap(follow.departure)
        }
        let curve = try XCTUnwrap(ShellCurve(wire: 4, custom: nil))
        for elapsed in [0.02, 0.05, 0.09] {
            let time = departure.begin + elapsed
            let progress = Double(curve.value(at: elapsed / 0.2))
            let exitScale = 1 - 0.4 * progress
            let shown = outer.rect(at: time)
            let scale = shown.width / targetLayout.width
            let expectedCentre = CGPoint(
                x: shown.minX + scale * (-40 * progress + targetLayout.width * exitScale / 2),
                y: shown.minY + scale * (20 * progress + targetLayout.height * exitScale / 2)
            )
            let ownProgress = try ShellLayerScene.engineQueue.sync {
                try XCTUnwrap(surface.scene.shapeTracks.entries[state.slot]?.plan).state(at: time).progress
            }
            XCTAssertGreaterThan(ownProgress, 0.1)
            let rect = try retainedRect(state, at: time)
            print("RETAINED-TARGET-EXIT", elapsed, "glass", rect, "expected", expectedCentre)
            let pixelScale = surface.scene.scale
            XCTAssertEqual(rect.midX * pixelScale, expectedCentre.x * pixelScale, accuracy: 0.5)
            XCTAssertEqual(rect.midY * pixelScale, expectedCentre.y * pixelScale, accuracy: 0.5)
            XCTAssertEqual(rect.width * pixelScale, shown.width * exitScale * ownProgress * pixelScale, accuracy: 0.5)
            XCTAssertEqual(rect.height * pixelScale, shown.height * exitScale * ownProgress * pixelScale, accuracy: 0.5)
        }
    }
}
