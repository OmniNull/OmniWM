// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
extension ShellManipulationSurfaceTests {
    final class Clock {
        var now = CACurrentMediaTime()
    }

    static let home = CGRect(x: 80, y: 70, width: 100, height: 80)

    static let followBody = """
    local home={x=80,y=70,w=100,h=80}
    local vars=ctx.data.vars or {}
    local rect=vars.x and {x=vars.x,y=70,w=100,h=80} or ctx.state.rect or home
    local function handle(next,event)
        if event.phase=='ended' then
            next.state.rect=event.rect
            next.state.transaction=event.transaction
        end
    end
    return ui.stack{w=600,h=400,
        ui.box{decorative=true,w=600,h=400,fill='accent'},
        ui.stack{key='widget',align='topLeading',dx=rect.x,dy=rect.y,w=rect.w,h=rect.h,
            manipulationCommit=vars.commit or ctx.state.transaction,
            manipulationFollow={response=0.363,bounce=0.42},fill='surface',
            ui.box{key='move',align='topLeading',w=100,h=20,onGesture=handle,
                gesture={axis='free',track={mode='move',target='widget',bounds={w=600,h=400},
                    min={w=50,h=40},max={w=300,h=240}}}},
            ui.input{key='note',align='topLeading',dy=30,w=80,h=25,text='stateful note'},
            ui.box{key='scale',align='bottomTrailing',w=12,h=12,animate='spring',onGesture=handle,
                gesture={track={mode='scale',target='widget',edge='se',bounds={w=600,h=400},
                    min={w=50,h=40},max={w=100,h=80}}}}}}
    """

    static let snapBody = followBody.replacingOccurrences(
        of: "next.state.rect=event.rect", with: "next.state.rect=home"
    )

    static let shiftBody = followBody.replacingOccurrences(
        of: "ui.stack{key='widget'",
        with: "ui.stack{key='frame',align='topLeading',dx=vars.shift or 0,w=600,h=400,ui.stack{key='widget'"
    ) + "}"

    var desk: ShellSpringDynamics.Parameters {
        get throws {
            try XCTUnwrap(ShellSpringDynamics.Parameters(
                ShellAnimation(motion: .spring(response: 0.363, bounce: 0.42), speed: 1)
            ))
        }
    }

    func follow(_ body: String = followBody, clock: Clock) throws -> Fixture {
        try Fixture(body, animations: true) { clock.now }
    }

    func presented(_ fixture: Fixture) throws -> CGRect {
        try CGRect(fixture.surface.presentedFrame(of: fixture.target()))
    }

    func record(_ fixture: Fixture) throws -> ShellManipulationFollow? {
        try fixture.surface.follows[fixture.target()]
    }

    func commitMove(_ fixture: Fixture, to point: CGPoint, clock: Clock) throws {
        fixture.beginMove(to: point)
        clock.now += 0.05
        let invocation = try fixture.releaseMove(at: point)
        try fixture.invokeRelease()
        fixture.render(acknowledgement: invocation)
        XCTAssertNil(fixture.surface.manipulation)
        XCTAssertNotNil(try record(fixture)?.motion)
    }

    func wrapper(_ fixture: Fixture) throws -> ShellGestureLayer {
        let scene = fixture.surface.scene
        let slot = try fixture.target().slot
        return try ShellLayerScene.engineQueue.sync { try XCTUnwrap(scene.gestureLayers[slot]) }
    }

    func attachRenderer(_ fixture: Fixture) throws -> ShellOffscreenRenderer {
        let container = fixture.surface.scene.container
        return try ShellLayerScene.engineQueue.sync {
            container.removeFromSuperlayer()
            return try ShellOffscreenRenderer(root: container, width: 600, height: 400)
        }
    }

    func completion(_ fixture: Fixture) throws -> (ShellManipulationCompletion, CAAnimation) {
        let layer = try wrapper(fixture).layer
        return try ShellLayerScene.engineQueue.sync {
            let animation = try XCTUnwrap(ShellManipulationSceneTests.keys.lazy.compactMap {
                layer.animation(forKey: $0)
            }.first { $0.delegate is ShellManipulationCompletion })
            return try (XCTUnwrap(animation.delegate as? ShellManipulationCompletion), animation)
        }
    }

    func drain() async {
        ShellLayerScene.engineQueue.sync {}
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func setVars(_ fixture: Fixture, _ key: String, _ value: Double, commit: String? = nil) {
        var writer = ShellValueWriter()
        writer.map(commit == nil ? 1 : 2)
        writer.key(key)
        writer.number(value)
        if let commit {
            writer.key("commit")
            writer.string(commit)
        }
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(fixture.script.instance, "vars", $0.baseAddress, $0.count)
        }, OMNI_OK)
    }

    func assertEqual(_ actual: CGRect, _ expected: CGRect, accuracy: CGFloat = 1e-4, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, line: line)
    }

    func testFollowDragPreviewsOneToOneAndPresentsTheAnalyticLag() throws {
        let clock = Clock()
        let fixture = try follow(clock: clock)
        let surface = fixture.surface
        let move = surface.layout.core.elements { $0.gestureTrack != 0 }.first {
            surface.layout.core.layoutFrame(of: $0).width == 100
        }
        let input = try XCTUnwrap(surface.textInputs.keys.first)
        let anchor = surface.anchor(of: input).frame
        fixture.beginMove(to: CGPoint(x: 185, y: 75))
        XCTAssertEqual(surface.manipulation?.preview, CGRect(x: 180, y: 70, width: 100, height: 80))
        try assertEqual(presented(fixture), Self.home)
        clock.now += 0.016
        let lag = try ShellSpringDynamics.position(at: 0.016, displacement: -100, initialVelocity: 0, spring: desk)
        let shown = try presented(fixture)
        assertEqual(shown, CGRect(x: 180 + lag, y: 70, width: 100, height: 80))
        XCTAssertLessThan(shown.minX, 90)
        XCTAssertEqual(surface.element(at: CGPoint(x: shown.minX + 5, y: 75)) { $0.acceptsPointer }, move)
        XCTAssertNotEqual(surface.element(at: CGPoint(x: 250, y: 75)) { $0.acceptsPointer }, move)
        XCTAssertEqual(surface.anchor(of: input).frame.minX - anchor.minX, shown.minX - 80, accuracy: 1e-3)
        surface.layoutTextInputs()
        XCTAssertEqual(try XCTUnwrap(surface.textInputs[input]).view.frame.minX, shown.minX, accuracy: 1e-3)
        surface.cancelInput()
    }

    func testReleaseKeepsTheFollowMotionWithoutAFling() throws {
        let clock = Clock()
        let fixture = try follow(clock: clock)
        let surface = fixture.surface
        fixture.beginMove(to: CGPoint(x: 185, y: 75))
        clock.now += 0.05
        let before = try XCTUnwrap(record(fixture)?.motion)
        _ = try fixture.releaseMove(at: CGPoint(x: 185, y: 75))
        let ended = try XCTUnwrap(fixture.events.last { $0.event.phase == .ended })
        XCTAssertEqual(ended.event.placement?.rect, CGRect(x: 180, y: 70, width: 100, height: 80))
        let after = try XCTUnwrap(record(fixture)?.motion)
        XCTAssertEqual(after.begin, clock.now)
        assertEqual(after.rect(at: clock.now), before.rect(at: clock.now))
        XCTAssertEqual(after.startVelocity.x, before.velocity(at: clock.now).x, accuracy: 1e-9)
        XCTAssertEqual(after.startVelocity.y, 0)
        let released = try presented(fixture).minX
        clock.now += 0.1
        let later = try presented(fixture).minX
        XCTAssertGreaterThan(later, released)
        XCTAssertLessThan(later, 180)
        surface.cancelInput()
    }

    func testRootChosenCommitSettlesHomeAndAppliesHome() async throws {
        let clock = Clock()
        let fixture = try follow(Self.snapBody, clock: clock)
        let surface = fixture.surface
        fixture.beginMove(to: CGPoint(x: 385, y: 75))
        clock.now += 0.05
        let invocation = try fixture.releaseMove(at: CGPoint(x: 385, y: 75))
        let held = try presented(fixture)
        let applied = expectation(description: "home applied")
        fixture.observed = { click in
            if click.event.phase == .applied { applied.fulfill() }
        }
        try fixture.invokeRelease()
        fixture.render(acknowledgement: invocation)
        XCTAssertNil(surface.manipulation)
        XCTAssertEqual(CGRect(try surface.layout.core.absoluteFrame(of: fixture.target())), Self.home)
        XCTAssertEqual(try record(fixture)?.motion?.target, Self.home)
        try assertEqual(presented(fixture), held)
        XCTAssertFalse(fixture.events.contains { $0.event.phase == .cancelled })
        let state = try wrapper(fixture)
        XCTAssertEqual(state.token, try record(fixture)?.token)
        XCTAssertTrue(state.moving)
        XCTAssertFalse(state.active)
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(fixture.events.last?.event.placement?.rect, Self.home)
    }

    func testPressDuringHoldSpringsBackContinuously() throws {
        let clock = Clock()
        let fixture = try follow(clock: clock)
        let surface = fixture.surface
        fixture.beginMove(to: CGPoint(x: 185, y: 75))
        clock.now += 0.05
        _ = try fixture.releaseMove(at: CGPoint(x: 185, y: 75))
        clock.now += 0.03
        let held = try presented(fixture)
        surface.press(at: CGPoint(x: 400, y: 300), timestamp: 0.03)
        XCTAssertNil(surface.manipulation)
        XCTAssertEqual(fixture.events.last?.event.reason, "superseded")
        try assertEqual(presented(fixture), held)
        XCTAssertEqual(try record(fixture)?.motion?.target, Self.home)
        let state = try wrapper(fixture)
        XCTAssertEqual(state.token, try record(fixture)?.token)
        XCTAssertTrue(state.moving)
        surface.cancelInput()
    }

    func testDisplayChangeDuringAFollowDragPresentsImmediately() throws {
        let clock = Clock()
        let fixture = try follow(clock: clock)
        let surface = fixture.surface
        fixture.beginMove(to: CGPoint(x: 185, y: 75))
        clock.now += 0.03
        XCTAssertNotNil(try record(fixture)?.motion)
        surface.setRootLimit(CGSize(width: 500, height: 350))
        XCTAssertNil(surface.manipulation)
        XCTAssertNil(surface.presentation)
        XCTAssertNil(try record(fixture)?.motion)
        try assertEqual(presented(fixture), Self.home)
        let state = try wrapper(fixture)
        XCTAssertFalse(state.moving)
        XCTAssertFalse(state.active)
        XCTAssertEqual(state.layer.transform.m41, 0)
        XCTAssertEqual(state.layer.transform.m11, 1)
    }

    func testFrameChangeDuringADragRebasesWithoutMovingThePresentedRect() throws {
        let clock = Clock()
        let fixture = try follow(Self.shiftBody, clock: clock)
        let surface = fixture.surface
        let target = try fixture.target()
        fixture.beginMove(to: CGPoint(x: 185, y: 75))
        clock.now += 0.03
        let shown = try presented(fixture)
        let generation = try wrapper(fixture).generation
        let layout = CGRect(surface.layout.core.absoluteFrame(of: target))
        setVars(fixture, "shift", -10)
        fixture.render()
        XCTAssertNotNil(surface.manipulation)
        let moved = CGRect(surface.layout.core.absoluteFrame(of: target))
        XCTAssertEqual(moved.origin, CGPoint(x: layout.minX - 10, y: layout.minY))
        try assertEqual(presented(fixture), shown)
        XCTAssertEqual(try record(fixture)?.frame, moved)
        XCTAssertEqual(try wrapper(fixture).generation, generation + 1)
        surface.cancelInput()
    }

    func testCommitChangeOutsideAManipulationSettlesWhileOtherMovesPresentImmediately() throws {
        let clock = Clock()
        let fixture = try follow(clock: clock)
        setVars(fixture, "x", 200, commit: "place-1")
        fixture.render()
        let motion = try XCTUnwrap(record(fixture)?.motion)
        XCTAssertEqual(motion.target, CGRect(x: 200, y: 70, width: 100, height: 80))
        try assertEqual(presented(fixture), Self.home)
        XCTAssertTrue(try wrapper(fixture).moving)

        let still = try follow(clock: clock)
        setVars(still, "x", 200)
        still.render()
        XCTAssertNil(try record(still)?.motion)
        XCTAssertNil(still.surface.presentation)
        try assertEqual(presented(still), CGRect(x: 200, y: 70, width: 100, height: 80))
        still.surface.setRootLimit(CGSize(width: 500, height: 350))
        XCTAssertNil(try record(still)?.motion)
        XCTAssertNil(still.surface.presentation)
    }
}
