// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellFollowReviewTests: XCTestCase {
    private typealias Fixture = ShellManipulationSurfaceTests.Fixture
    private let helper = ShellManipulationSurfaceTests()
    private let pixels = ShellGlassSceneTests()

    private static let body = """
    local vars=ctx.data.vars or {}
    local target={key='widget',align='topLeading',dx=80,dy=70,w=100,h=80,
        manipulationFollow={response=0.363,bounce=0.42},
        ui.box{key='scale',align='bottomTrailing',w=12,h=12,onGesture=function() end,
            gesture={track={mode='scale',target='widget',edge='se',bounds={w=600,h=400},
                min={w=50,h=40},max={w=100,h=80}}}}}
    return ui.stack{w=600,h=400,
        if vars.replace then ui.box(target) else ui.stack(target),
        ui.glass{key='panes',align='topLeading',dx=vars.bodyX or 0,w=600,h=400,
            backdrop=false,fill='#FFFFFFFF',shadow='#00000000',rim=0,blend=0,
            ui.shape{key='follower',align='topLeading',dx=80,dy=70,w=100,h=80,
                follow='widget',radius=0}}}
    """

    private func stage(_ fixture: Fixture, at time: CFTimeInterval) throws -> ShellGlassSceneTests.FollowStage {
        try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            let root = scene.container
            root.removeFromSuperlayer()
            root.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
            root.isGeometryFlipped = true
            root.speed = 0
            root.timeOffset = time
            let renderer = try ShellOffscreenRenderer(root: root, width: 600, height: 400)
            _ = try renderer.render(paused: time)
            return .init(scene: scene, renderer: renderer, width: 600, height: 400)
        }
    }

    private func scale(_ fixture: Fixture) throws {
        fixture.surface.press(at: CGPoint(x: 175, y: 145), timestamp: 0)
        fixture.surface.drag(to: CGPoint(x: 125, y: 105), screen: .zero, timestamp: 0.01)
        ShellLayerScene.engineQueue.sync {}
        let current = try XCTUnwrap(fixture.surface.manipulation)
        XCTAssertEqual(current.preview.width / current.start.width, 0.5, accuracy: 1e-9)
    }

    private func composed(_ fixture: Fixture, shape: ElementHandle, target: ElementHandle) -> CGRect {
        let surface = fixture.surface
        let layout = CGRect(surface.layout.core.absoluteFrame(of: target))
        let own = CGRect(surface.layout.core.absoluteFrame(of: shape))
        let shown = CGRect(surface.presentedFrame(of: target))
        let factor = shown.width / layout.width
        return CGRect(
            x: shown.minX + (own.minX - layout.minX) * factor,
            y: shown.minY + (own.minY - layout.minY) * factor,
            width: own.width * factor,
            height: own.height * factor
        )
    }

    private func assertDrawn(
        _ stage: ShellGlassSceneTests.FollowStage,
        at time: CFTimeInterval,
        equals expected: CGRect,
        _ message: String,
        line: UInt = #line
    ) throws {
        let actual = try pixels.drawn(stage, at: time, around: CGRect(x: 104, y: 89, width: 2, height: 2))
        print("FOLLOW-REVIEW", message, "drawn", actual, "expected", expected)
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, message, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, message, line: line)
        XCTAssertEqual(actual.maxX, expected.maxX, accuracy: 1, message, line: line)
        XCTAssertEqual(actual.maxY, expected.maxY, accuracy: 1, message, line: line)
    }

    func testFollowReviewBodyOnlyMoveRecomposesTheRetainedFollowerAndIdentityClearsIt() throws {
        let time = CACurrentMediaTime()
        let fixture = try Fixture(Self.body, animations: false, clock: { time })
        let stage = try stage(fixture, at: time)
        let target = try fixture.target()
        let shape = try helper.shape(fixture, "follower")
        try pixels.requireNative(stage, try helper.shape(fixture, "panes").slot)
        try scale(fixture)
        try assertDrawn(stage, at: time, equals: composed(fixture, shape: shape, target: target), "before body move")
        let local = fixture.surface.layout.core.layoutFrame(of: shape)
        helper.setValues(fixture, numbers: ["bodyX": 10])
        fixture.render()
        XCTAssertEqual(try helper.shape(fixture, "follower"), shape)
        XCTAssertEqual(fixture.surface.layout.core.layoutFrame(of: shape), local)
        let expected = composed(fixture, shape: shape, target: target)
        XCTAssertEqual(expected.minX, 85, accuracy: 1e-9)
        try assertDrawn(stage, at: time, equals: expected, "body-only move")
        fixture.surface.cancelInput()
        ShellLayerScene.engineQueue.sync {}
        try assertDrawn(
            stage, at: time, equals: CGRect(fixture.surface.layout.core.absoluteFrame(of: shape)), "identity clears"
        )
    }

    func testFollowReviewSameKeyTargetReplacementResetsTheRetainedFollower() throws {
        let time = CACurrentMediaTime()
        let fixture = try Fixture(Self.body, animations: false, clock: { time })
        let stage = try stage(fixture, at: time)
        let oldTarget = try fixture.target()
        let shape = try helper.shape(fixture, "follower")
        try scale(fixture)
        try assertDrawn(
            stage, at: time, equals: composed(fixture, shape: shape, target: oldTarget), "before replacement"
        )
        helper.setValues(fixture, flags: ["replace": true])
        fixture.render()
        let target = try fixture.target()
        XCTAssertNotEqual(target, oldTarget)
        XCTAssertEqual(try helper.shape(fixture, "follower"), shape)
        XCTAssertNil(fixture.surface.manipulation)
        XCTAssertTrue(fixture.surface.currentPresentation(of: target).isIdentity)
        let expected = composed(fixture, shape: shape, target: target)
        try assertDrawn(stage, at: time, equals: expected, "same-key target replacement")
        fixture.surface.scene.submit(fixture.surface.manipulationCommands(
            target, token: ShellInvocation.next(), presentation: .identity, active: false
        ), animated: false)
        ShellLayerScene.engineQueue.sync {}
        try assertDrawn(stage, at: time, equals: expected, "explicit identity clears")
    }
}
