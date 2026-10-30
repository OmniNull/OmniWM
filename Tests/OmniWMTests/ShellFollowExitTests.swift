// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellFollowExitTests: XCTestCase {
    private typealias Fixture = ShellManipulationSurfaceTests.Fixture
    private let inputs = ShellManipulationSurfaceTests()
    private let glass = ShellGlassSceneTests()

    private static let body = """
    local open=not (ctx.data.vars or {}).closed
    local drip={response=0.482,bounce=0.31}
    local morph={anchor={x=1,y=0.5},stops={{at=0,scale=0},{at=1,scale=1}}}
    return ui.stack{key='root',w=600,h=400,
        ui.glass{key='panes',align='topLeading',w=600,h=400,
            backdrop=false,fill='#FFFFFFFF',shadow='#00000000',rim=0,blend=0,
            open and ui.shape{key='desk-shape',align='topLeading',dx=200,dy=100,w=100,h=80,
                radius=0,follow='desk',reveal=drip,morph=morph} or nil},
        open and ui.stack{key='desk',align='topLeading',dx=200,dy=100,w=100,h=80,
            reveal=drip,manipulationFollow={response=0.363,bounce=0.42},
            exit={dx=-120,dy=-30,scale=2,anchor={x=0,y=0},animate={response=0.363,bounce=0.42}},
            ui.box{key='grip',align='topLeading',w=100,h=12,onGesture=function() end,
                gesture={track={mode='move',target='desk',bounds={w=600,h=400},
                    min={w=50,h=40},max={w=200,h=160}}}},
            ui.box{key='content',w=100,h=80,fill='#FFFFFFFF',morph=morph}} or nil}

    """

    private struct Stage {
        let pixels: ShellGlassSceneTests.FollowStage
        let panes: CALayer
        let content: CALayer
        let closing: ShellReveal
    }

    private func stage(_ fixture: Fixture, at begin: CFTimeInterval) throws -> Stage {
        let surface = fixture.surface
        let pane = try inputs.shape(fixture, "panes")
        let shape = try inputs.shape(fixture, "desk-shape")
        let target = try fixture.target()
        XCTAssertNil(surface.reveals[target]?.plan)
        XCTAssertNil(surface.reveals[shape]?.plan)
        let renderer = try ShellLayerScene.engineQueue.sync {
            let root = surface.scene.container
            root.removeFromSuperlayer()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
            root.isGeometryFlipped = true
            root.speed = 0
            root.timeOffset = begin
            CATransaction.commit()
            let renderer = try ShellOffscreenRenderer(root: root, width: 600, height: 400)
            _ = try renderer.render(paused: begin)
            return renderer
        }
        inputs.setValues(fixture, flags: ["closed": true])
        fixture.render()
        XCTAssertEqual(try inputs.shape(fixture, "panes"), pane)
        XCTAssertTrue(surface.layout.core.contains(pane))
        XCTAssertFalse(surface.layout.core.contains(target))
        XCTAssertFalse(surface.layout.core.contains(shape))
        return try ShellLayerScene.engineQueue.sync {
            let scene = surface.scene
            _ = try ShellGlassSceneTests.native(scene.glassBodies[pane.slot])
            let retained = try XCTUnwrap(scene.presence.retained.values.first {
                $0.identity?.key == VitreusFixture.key("desk")
            })
            let entry = try XCTUnwrap(scene.shapeTracks.entries.values.first { $0.carrier != nil })
            let closing = try XCTUnwrap(entry.plan)
            XCTAssertNotNil(scene.shapeTracks.follows[entry.base.target.slot]?.departure)
            XCTAssertEqual(closing.target, 0)
            XCTAssertEqual(closing.progress, 1)
            XCTAssertEqual(closing.commit, begin)
            return Stage(
                pixels: .init(scene: scene, renderer: renderer, width: 600, height: 400),
                panes: try XCTUnwrap(scene.layers[pane.slot]), content: retained.subtree, closing: closing
            )
        }
    }

    private func drawn(_ stage: Stage, at time: CFTimeInterval, around expected: CGRect, pane: Bool) throws -> CGRect {
        ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stage.panes.isHidden = !pane
            stage.content.isHidden = pane
            CATransaction.commit()
        }
        defer {
            ShellLayerScene.engineQueue.sync {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                stage.panes.isHidden = false
                stage.content.isHidden = false
                CATransaction.commit()
            }
        }
        return try glass.drawn(stage.pixels, at: time, around: expected)
    }

    func testClosingAMovedHalfScaledTargetCarriesItsExitIntoTheRetainedFollower() throws {
        let begin = CACurrentMediaTime()
        let fixture = try Fixture(Self.body, animations: true, clock: { begin })
        let stage = try stage(fixture, at: begin)
        let spring = try inputs.desk
        let returning = try XCTUnwrap(ShellManipulationMotion(
            from: CGRect(x: 200, y: 100, width: 100, height: 80),
            to: CGRect(x: 80, y: 70, width: 200, height: 160), begin: begin, spring: spring
        ))
        for elapsed in [0.0, 0.03, 0.06, 0.1, 0.14] {
            let time = begin + elapsed
            let rect = returning.rect(at: time)
            let progress = stage.closing.state(at: time).progress
            XCTAssertGreaterThan(progress, 0.15)
            let expected = CGRect(
                x: rect.maxX - rect.width * progress,
                y: rect.midY - rect.height * progress / 2,
                width: rect.width * progress, height: rect.height * progress
            )
            let content = try drawn(stage, at: time, around: expected, pane: false)
            let pane = try drawn(stage, at: time, around: expected, pane: true)
            print("FOLLOW-EXIT", elapsed, "content", content, "glass", pane, "expected", expected)
            glass.assertRect(content, expected, accuracy: 1, "content at \(elapsed)")
            glass.assertRect(pane, content, accuracy: 1, "glass follows the closing content at \(elapsed)")
        }
    }

    func testClosingADeskWithADelayedEaseExitKeepsTheGlassOnItsContent() throws {
        let begin = CACurrentMediaTime()
        let body = Self.body.replacingOccurrences(
            of: "animate={response=0.363,bounce=0.42}", with: "delay=0.04,animate='ease'"
        )
        let fixture = try Fixture(body, animations: true, clock: { begin })
        let stage = try stage(fixture, at: begin)
        let curve = try XCTUnwrap(ShellCurve(wire: 4, custom: nil))
        for elapsed in [0.0, 0.03, 0.04, 0.06, 0.1, 0.14] {
            let time = begin + elapsed
            let amount = Double(curve.value(at: max(0, elapsed - 0.04) / 0.2))
            let rect = CGRect(
                x: 200 - 120 * amount,
                y: 100 - 30 * amount,
                width: 100 * (1 + amount),
                height: 80 * (1 + amount)
            )
            let progress = stage.closing.state(at: time).progress
            let expected = CGRect(
                x: rect.maxX - rect.width * progress, y: rect.midY - rect.height * progress / 2,
                width: rect.width * progress, height: rect.height * progress
            )
            let content = try drawn(stage, at: time, around: expected, pane: false)
            let pane = try drawn(stage, at: time, around: expected, pane: true)
            print("FOLLOW-EASE-EXIT", elapsed, "content", content, "glass", pane, "expected", expected)
            glass.assertRect(content, expected, accuracy: 1, "content at \(elapsed)")
            glass.assertRect(pane, content, accuracy: 1, "glass follows the delayed exit at \(elapsed)")
        }
    }

    func testAnExitAndWrapperScaleKeepAFixedRadiusInBodySpace() {
        let shape = ShellGlassShape(
            slot: 2,
            kind: 0,
            rect: CGRect(x: 20, y: 30, width: 100, height: 80),
            radius: 10,
            thickness: 0
        )
        var follow = ShellShapeFollow(
            radius: .fixed, presentation: .still(translation: .zero, scale: 0.8, clip: nil),
            departure: ShellShapeDeparture(
                origin: shape.rect.origin,
                from: SIMD3(0, 0, 1),
                to: SIMD3(0, 0, 2),
                spring: nil,
                curve: nil,
                begin: 0,
                duration: 0
            )
        )
        let fixed = follow.shape(shape, origin: shape.rect.origin, at: .infinity)
        XCTAssertEqual(fixed.rect.width, 160, accuracy: 1e-9)
        XCTAssertEqual(fixed.radius, 10, accuracy: 1e-9)
        follow.radius = .scaled
        let scaled = follow.shape(shape, origin: shape.rect.origin, at: .infinity)
        XCTAssertEqual(scaled.rect, fixed.rect)
        XCTAssertEqual(scaled.radius, 16, accuracy: 1e-9)
    }
}
