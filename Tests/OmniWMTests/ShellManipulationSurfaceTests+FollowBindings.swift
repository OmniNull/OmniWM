// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
extension ShellManipulationSurfaceTests {
    static let bindingBody = """
    local vars=ctx.data.vars or {}
    return ui.stack{w=600,h=400,
        ui.stack{key='a',align='topLeading',dx=40,dy=40,w=100,h=80,
            manipulationFollow={response=0.363,bounce=0.42},fill='surface',
            ui.box{align='topLeading',w=100,h=20,onGesture=function() end,
                gesture={axis='free',track={mode='move',target='a',bounds={w=600,h=400},
                    min={w=50,h=40},max={w=300,h=240}}}}},
        ui.glass{key='panes',w=600,h=400,
            ui.shape{key='card',align='topLeading',follow=if vars.unbound then nil else 'a',
                followRadius=if vars.fixed and not vars.unbound then 'fixed' else nil,
                dx=50,dy=130,w=80,h=30,radius=8}}}
    """

    func testFollowUnbindingAndRadiusPolicyChangesReachTheScene() throws {
        let fixture = try follow(Self.bindingBody, clock: Clock())
        let card = try shape(fixture, "card")
        let scene = fixture.surface.scene
        func binding() -> ShellShapeFollow? {
            ShellLayerScene.engineQueue.sync { scene.shapeTracks.follows[card.slot] }
        }
        XCTAssertEqual(binding()?.radius, .scaled)
        setValues(fixture, flags: ["fixed": true])
        fixture.render()
        XCTAssertTrue(fixture.surface.layout.core.content(of: card).glassFollowFixedRadius)
        XCTAssertEqual(binding()?.radius, .fixed)
        setValues(fixture, flags: ["unbound": true])
        fixture.render()
        XCTAssertEqual(fixture.surface.layout.core.content(of: card).glassFollow, 0)
        XCTAssertNil(binding())
    }

    func testFixedRadiusFollowerHitsUseItsUnscaledCorner() throws {
        let corner = CGPoint(x: 53, y: 133)
        for (policy, inside) in [("", false), (",followRadius='fixed'", true)] {
            let body = Self.pairBody.replacingOccurrences(of: "radius=8}", with: "radius=8\(policy)}")
            let both = try pair(body, clock: Clock())
            let surface = both.fixture.surface
            _ = try commitScaled(both)
            XCTAssertTrue(surface.containsShape(at: CGPoint(x: 90, y: 145)), policy)
            XCTAssertEqual(surface.containsShape(at: corner), inside, policy)
            XCTAssertFalse(surface.containsShape(at: CGPoint(x: 51, y: 131)), policy)
            surface.cancelInput()
        }
    }

    func testSettleCompletionReturnsFollowersToIdentityWithoutHeldSprings() async throws {
        let both = try pair(clock: Clock())
        let renderer = try attachRenderer(both.fixture)
        let surface = both.fixture.surface
        let card = try shape(both.fixture, "card")
        _ = try commitScaled(both)
        let keys = ["omni.follow.translation.x", "omni.follow.translation.y", "omni.follow.scale"]
        func held() throws -> (follow: ShellShapeFollow, springs: Int) {
            try ShellLayerScene.engineQueue.sync {
                let scene = surface.scene
                let follow = try XCTUnwrap(scene.shapeTracks.follows[card.slot])
                let body = try XCTUnwrap(scene.parents[card.slot].flatMap { scene.glassBodies[$0] })
                let springs = body.lockstepLayers(card.slot).reduce(0) { count, layer in
                    count + keys.count { layer.animation(forKey: $0) != nil }
                }
                return (follow, springs)
            }
        }
        let moving = try held()
        XCTAssertEqual(moving.follow.mode, .transform)
        XCTAssertGreaterThan(moving.springs, 0)
        let (completion, animation) = try ShellLayerScene.engineQueue.sync {
            let layer = try XCTUnwrap(surface.scene.gestureLayers[both.left.slot]?.layer)
            let animation = try XCTUnwrap(ShellManipulationSceneTests.keys.lazy.compactMap {
                layer.animation(forKey: $0)
            }.first { $0.delegate is ShellManipulationCompletion })
            return try (XCTUnwrap(animation.delegate as? ShellManipulationCompletion), animation)
        }
        completion.animationDidStop(animation, finished: true)
        await drain()
        XCTAssertNil(surface.follows[both.left]?.motion)
        let settled = try held()
        XCTAssertEqual(settled.follow.mode, ShellShapeFollow.Mode.none)
        XCTAssertTrue(settled.follow.presentation.isIdentity)
        XCTAssertEqual(settled.springs, 0)
        withExtendedLifetime(renderer) {}
    }

    func testIdleHeightReflowSpringsAFollowTargetAndItsGlassWithTheTargetsSpring() throws {
        let body = Self.bindingBody.replacingOccurrences(
            of: "dx=40,dy=40,w=100,h=80,", with: "dx=40,dy=40,w=100,h=vars.h or 80,animate={response=0.5,bounce=0},"
        ).replacingOccurrences(of: "dx=50,dy=130,w=80,h=30,", with: "dx=40,dy=40,w=100,h=vars.h or 80,")
        let fixture = try follow(body, clock: Clock())
        let renderer = try attachRenderer(fixture)
        let surface = fixture.surface
        let target = try fixture.target()
        let card = try shape(fixture, "card")
        setValues(fixture, numbers: ["h": 120])
        fixture.render()
        XCTAssertEqual(surface.layout.core.absoluteFrame(of: target).height, 120)
        XCTAssertNil(surface.follows[target]?.motion)
        let scene = surface.scene
        let (keys, spring) = ShellLayerScene.engineQueue.sync {
            (scene.layers[target.slot]?.animationKeys() ?? [], scene.shapeTracks.entries[card.slot]?.base.spring)
        }
        XCTAssertTrue(keys.contains { $0.hasPrefix("bounds") }, "\(keys)")
        XCTAssertEqual(
            spring, ShellSpringDynamics.Parameters(ShellAnimation(motion: .spring(response: 0.5, bounce: 0), speed: 1))
        )
        withExtendedLifetime(renderer) {}
    }

    func testManipulationAndFollowChangesDiscardTheFollowSnapshot() throws {
        let fixture = try follow(clock: Clock())
        let surface = fixture.surface
        surface.followChangeSnapshot = []
        fixture.beginMove(to: CGPoint(x: 185, y: 75))
        XCTAssertNil(surface.followChangeSnapshot)
        surface.followChangeSnapshot = []
        surface.cancelManipulation(reason: "test", immediate: true)
        XCTAssertNil(surface.followChangeSnapshot)
        surface.followChangeSnapshot = []
        surface.follows.removeAll()
        XCTAssertNil(surface.followChangeSnapshot)
    }

    func testIdleResizeAnimatesAFollowTargetsSubtreeOnlyWhenTheTargetAnimates() throws {
        for animated in [false, true] {
            let body = Self.followBody.replacingOccurrences(
                of: "w=rect.w,h=rect.h,",
                with: "w=rect.w,h=vars.h or rect.h,\(animated ? "animate={response=0.5,bounce=0}," : "")"
            )
            let fixture = try follow(body, clock: Clock())
            let renderer = try attachRenderer(fixture)
            let surface = fixture.surface
            let handle = try XCTUnwrap(surface.layout.core.elements { $0.gestureTrack != 0 }.first {
                surface.layout.core.layoutFrame(of: $0).width == 12
            })
            setVars(fixture, "h", 120)
            fixture.render()
            XCTAssertNil(try record(fixture)?.motion)
            let scene = surface.scene
            let keys = ShellLayerScene.engineQueue.sync { scene.layers[handle.slot]?.animationKeys() ?? [] }
            XCTAssertEqual(keys.contains { $0.hasPrefix("position") || $0.hasPrefix("bounds") }, animated, "\(keys)")
            withExtendedLifetime(renderer) {}
        }
    }
}
