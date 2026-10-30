// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
extension ShellGlassSceneTests {
    func testFollowReviewEaseOnAnIdleTargetMatchesTheOrdinaryShapeAtStartMidpointAndEnd() throws {
        let script = try followReviewEaseScript()
        let text = ShellTextStore()
        let surface = ShellWidgetSurface(
            scale: 2,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: true)),
            directories: []
        )
        followReviewEaseRender(script, text: text, on: surface)
        let begin = CACurrentMediaTime()
        let (stage, ordinary) = try followReviewEaseStage(surface, begin: begin)
        XCTAssertEqual(omni_instance_set_number(script.instance, "cpu", 1), OMNI_OK)
        followReviewEaseRender(script, text: text, on: surface)
        try followReviewEaseAnimation(on: stage, slot: ordinary, begin: begin)
        try followReviewEaseSamples(stage, begin: begin)
    }

    private func followReviewEaseScript() throws -> ShellScriptHostTests.Script {
        try ShellScriptHostTests.Script("""
        function render(ctx)
            local x=30+60*(ctx.data.cpu or 0)
            return ui.stack{w=220,h=160,
                ui.stack{key='target',align='topLeading',dx=30,dy=20,w=80,h=40,
                    manipulationFollow={response=0.363,bounce=0.42},
                    ui.box{align='topLeading',w=80,h=12,onGesture=function() end,
                        gesture={axis='free',track={mode='move',target='target',bounds={w=220,h=160},
                            min={w=40,h=20},max={w=160,h=80}}}}},
                ui.glass{key='body',align='topLeading',w=220,h=160,blend=4,backdrop=false,rim=0,
                    fill='#FFFFFFFF',shadow='#00000000',
                    ui.shape{key='followed',align='topLeading',dx=x,dy=20,w=80,h=40,
                        follow='target',animate='ease'},
                    ui.shape{key='ordinary',align='topLeading',dx=x,dy=100,w=80,h=40,animate='ease'}}}
        end
        """)
    }

    private func followReviewEaseRender(
        _ script: ShellScriptHostTests.Script, text: ShellTextStore, on surface: ShellWidgetSurface
    ) {
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        text.ingest(wire: script.output)
        XCTAssertTrue(surface.apply(script.output, text: text))
        ShellLayerScene.engineQueue.sync {}
    }

    private func followReviewEaseStage(
        _ surface: ShellWidgetSurface, begin: CFTimeInterval
    ) throws -> (stage: FollowStage, ordinary: Int32) {
        let shapes = surface.layout.core.elements { _ in true }.filter {
            surface.layout.core.kind(of: $0) == .shape
        }
        let followed = try XCTUnwrap(shapes.first { surface.layout.core.content(of: $0).glassFollow != 0 })
        let ordinary = try XCTUnwrap(shapes.first { surface.layout.core.content(of: $0).glassFollow == 0 })
        let target = try XCTUnwrap(surface.manipulationTargets.keys.first)
        XCTAssertEqual(surface.layout.core.content(of: followed).glassFollow, surface.layout.core.key(of: target))
        XCTAssertNotNil(surface.follows[target])
        XCTAssertNil(surface.follows[target]?.motion)
        XCTAssertNil(surface.manipulation)
        let stage = try ShellLayerScene.engineQueue.sync {
            let container = surface.scene.container
            container.removeFromSuperlayer()
            container.frame = CGRect(x: 0, y: 0, width: 220, height: 160)
            container.isGeometryFlipped = true
            let renderer = try ShellOffscreenRenderer(root: container, width: 220, height: 160)
            _ = try renderer.render(paused: begin)
            return FollowStage(scene: surface.scene, renderer: renderer, width: 220, height: 160)
        }
        try ShellLayerScene.engineQueue.sync {
            let body = try XCTUnwrap(stage.scene.parents[followed.slot])
            _ = try Self.native(stage.scene.glassBodies[body])
            let follow = try XCTUnwrap(stage.scene.shapeTracks.follows[followed.slot])
            XCTAssertEqual(follow.radius, .scaled)
            XCTAssertTrue(follow.presentation.isIdentity)
        }
        return (stage, ordinary.slot)
    }

    private func followReviewEaseAnimation(on stage: FollowStage, slot: Int32, begin: CFTimeInterval) throws {
        try ShellLayerScene.engineQueue.sync {
            let body = try Self.native(stage.scene.parents[slot].flatMap { stage.scene.glassBodies[$0] })
            let animation = try XCTUnwrap(
                body.lockstepLayers(slot).first?.animation(forKey: ShellGlassBody.Channel.x.key)
                    as? CABasicAnimation
            )
            XCTAssertFalse(animation is CASpringAnimation)
            XCTAssertEqual(animation.duration, 0.2, accuracy: 1e-9)
            XCTAssertEqual(animation.beginTime, begin, accuracy: 1e-9)
        }
    }

    private func followReviewEaseSamples(_ stage: FollowStage, begin: CFTimeInterval) throws {
        for (elapsed, x) in [(0.0, 30.0), (0.1, 60.0), (0.2, 90.0)] {
            let time = begin + elapsed
            let followedRect = try drawn(
                stage, at: time, around: CGRect(x: 90, y: 20, width: 20, height: 40), rows: 0 ..< 80
            )
            let ordinaryRect = try drawn(
                stage, at: time, around: CGRect(x: 90, y: 100, width: 20, height: 40), rows: 80 ..< 160
            )
            let expected = CGRect(x: x, y: 20, width: 80, height: 40)
            followReviewEaseAssertRect(ordinaryRect.offsetBy(dx: 0, dy: -80), expected, "ordinary ease at \(elapsed)")
            followReviewEaseAssertRect(followedRect, expected, "followed ease at \(elapsed)")
            followReviewEaseAssertRect(
                followedRect, ordinaryRect.offsetBy(dx: 0, dy: -80),
                "idle follow preserves the ordinary ease at \(elapsed)"
            )
        }
    }

    private func followReviewEaseAssertRect(
        _ actual: CGRect, _ expected: CGRect, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(actual.maxX, expected.maxX, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(actual.maxY, expected.maxY, accuracy: 1, message, file: file, line: line)
    }

    func testFollowReviewEaseBaseUsesTheDeclaredSpeedCurveAndRetargetVelocity() throws {
        let from = ShellGlassShape(
            slot: 11, kind: 0, rect: CGRect(x: 30, y: 20, width: 80, height: 40), radius: 8, thickness: 0
        )
        let to = from.with(rect: from.rect.offsetBy(dx: 60, dy: 0))
        let animation = ShellAnimation(
            motion: .ease(seconds: 0.4), speed: 2,
            curve: try XCTUnwrap(ShellCurve(wire: 1, custom: nil))
        )
        let base = ShellShapeBaseMotion(from: from, to: to, begin: 1, ease: animation)
        XCTAssertEqual(base.duration, 0.2, accuracy: 1e-12)
        for elapsed in [0.025, 0.05, 0.1, 0.15] {
            let state = base.state(at: 1 + elapsed)
            XCTAssertEqual(state.shape.rect.minX, 30 + 300 * elapsed, accuracy: 1e-7)
            XCTAssertEqual(state.velocity[0], 300, accuracy: 1e-7)
        }
        let seed = base.state(at: 1.1)
        let retarget = ShellShapeBaseMotion(
            from: seed.shape, velocity: seed.velocity, to: from, begin: 1.1, spring: try Self.spring(Self.calm)
        )
        XCTAssertEqual(retarget.state(at: 1.1).shape.rect.minX, 60, accuracy: 1e-7)
        XCTAssertEqual(retarget.state(at: 1.1).velocity[0], 300, accuracy: 1e-7)
        XCTAssertEqual(base.rekeyed(to: 12).state(at: 1.1).shape.slot, 12)
        XCTAssertEqual(base.rekeyed(to: 12).state(at: 1.1).shape.rect.minX, 60, accuracy: 1e-7)
    }
}
