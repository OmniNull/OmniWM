// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

final class ShellGestureTrackMathTests: XCTestCase {
    func testTrackParserRejectsMalformedAndOutOfRangeChannels() throws {
        XCTAssertNotNil(ShellGestureTrack("track:1:0:20:0:0:0:0:1:1:0:1:1:0"))
        for recipe in [
            "track:0:0:20:0:0:0:0:1:1:0:1:1:0",
            "track:1:0:20:0:1:0:0:1:1:0:1:1:0",
            "track:1:0:20:1.1:0:0:0:1:1:0:1:1:0",
            "track:1:0:nan:0:0:0:0:1:1:0:1:1:0",
            "track:1:0:1000001:0:0:0:0:1:1:0:1:1:0",
            "track:8:0:0:0:0:0:0:1:1:0:1:2:0",
            "track:1:0:20:0"
        ] {
            XCTAssertNil(ShellGestureTrack(recipe), recipe)
        }
    }

    func testDirectionalRubberCarriesChannelVelocityAndClampsFactors() throws {
        let track = try XCTUnwrap(ShellGestureTrack("track:15:0:40:0.5:0:-40:0.5:1:0:1:1:0:1"))
        var configuration = ShellGestureConfig()
        configuration.commitDistance = 20
        configuration.direction = .up
        let inside = track.sample(
            translation: CGPoint(x: 0, y: -10),
            velocity: CGPoint(x: 0, y: -40),
            axis: .y,
            configuration: configuration
        )
        XCTAssertEqual(inside.value.dx, 20)
        XCTAssertEqual(inside.value.dy, -20)
        XCTAssertEqual(inside.value.scale, 0.5)
        XCTAssertEqual(inside.velocity.dx, 80)
        XCTAssertEqual(inside.velocity.dy, -80)
        let outside = track.sample(
            translation: CGPoint(x: 0, y: -40),
            velocity: CGPoint(x: 0, y: -40),
            axis: .y,
            configuration: configuration
        )
        XCTAssertEqual(outside.value.dx, 50)
        XCTAssertEqual(outside.velocity.dx, 10)
        XCTAssertEqual(outside.value.scale, 0)
        XCTAssertEqual(outside.value.opacity, 0)
        XCTAssertEqual(outside.velocity.scale, 0)
        XCTAssertEqual(outside.velocity.opacity, 0)
    }

    func testAnyDirectionUsesCapturedAxisAndInwardVelocity() {
        var configuration = ShellGestureConfig()
        configuration.commitDistance = 10
        configuration.direction = .any
        let axis = ShellGestureTrack.progress(
            translation: CGPoint(x: -5, y: 100),
            velocity: CGPoint(x: 2, y: 1000),
            axis: .x,
            configuration: configuration
        )
        XCTAssertEqual(axis.value, 0.5)
        XCTAssertEqual(axis.velocity, -0.2)
        let free = ShellGestureTrack.progress(
            translation: CGPoint(x: 3, y: 4),
            velocity: CGPoint(x: 6, y: 8),
            axis: .free,
            configuration: configuration
        )
        XCTAssertEqual(free.value, 0.5)
        XCTAssertEqual(free.velocity, 1)
    }
}

@MainActor
final class ShellGestureTrackTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let script: ShellScriptHostTests.Script
        let surface: ShellWidgetSurface
        let text = ShellTextStore()
        var events: [ShellClick] = []
        var lastInvocation: UInt64?

        init(_ body: String) throws {
            script = try ShellScriptHostTests.Script("function render(ctx) " + body + " end")
            surface = ShellWidgetSurface(
                scale: 2,
                resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
                directories: []
            )
            surface.onAction = { [weak self] click in
                guard let self else { return }
                events.append(click)
                if let token = click.event.trackingToken {
                    let invocation = ShellInvocation.next()
                    surface.bindGestureInvocation(trackToken: token, invocationID: invocation)
                    lastInvocation = invocation
                }
            }
            render()
        }

        func render(_ value: Double = 0, acknowledgement: UInt64 = 0) {
            XCTAssertEqual(omni_instance_set_number(script.instance, "seconds", value), OMNI_OK)
            XCTAssertEqual(script.render().status, OMNI_OK, script.message)
            text.ingest(wire: script.output)
            surface.sequence += 1
            XCTAssertTrue(surface.apply(script.output, text: text, gestureAcknowledgement: acknowledgement))
            ShellLayerScene.engineQueue.sync {}
        }

        func offset() -> Double? {
            let scene = surface.scene
            let slot = surface.layout.core.rootHandle.slot
            return ShellLayerScene.engineQueue.sync { scene.gestureLayers[slot].map { Double($0.layer.transform.m41) } }
        }
    }

    private let body = "return ui.box{key='root',w=40+ctx.data.seconds,h=20,fill='accent',gesture={axis='x',commit={distance=20,direction='right'},track={dx={0,20}}},onGesture=function() end}"

    func testTerminalOnlyGestureTracksNativelyAndHoldsThroughRedrawUntilMatchingAcknowledgement() throws {
        let fixture = try Fixture(body)
        let surface = fixture.surface
        surface.press(at: CGPoint(x: 3, y: 2), timestamp: 0)
        surface.drag(to: CGPoint(x: 13, y: 2), screen: .zero, timestamp: 0.01)
        XCTAssertEqual(fixture.offset(), 10)
        surface.drag(to: CGPoint(x: 18, y: 2), screen: .zero, timestamp: 0.02)
        XCTAssertEqual(fixture.offset(), 15)
        XCTAssertEqual(fixture.events.map(\.event.phase), [.began])
        surface.release(at: CGPoint(x: 28, y: 2), timestamp: 0.03)
        let invocation = try XCTUnwrap(fixture.lastInvocation)
        XCTAssertEqual(fixture.events.map(\.event.phase), [.began, .ended])
        XCTAssertEqual(surface.gestureTracking?.holding, true)
        XCTAssertEqual(fixture.offset(), 20)
        fixture.render(1)
        XCTAssertEqual(fixture.offset(), 20)
        surface.acknowledgeGesture(through: invocation - 1)
        XCTAssertEqual(fixture.offset(), 20)
        fixture.render(2, acknowledgement: invocation)
        XCTAssertEqual(fixture.offset(), 0)
        XCTAssertNil(surface.gestureTracking)
    }

    func testCancelSettlesImmediatelyUnderReduceMotionAndNeverWaitsForAcknowledgement() throws {
        let fixture = try Fixture(body)
        let surface = fixture.surface
        surface.press(at: CGPoint(x: 3, y: 2), timestamp: 0)
        surface.drag(to: CGPoint(x: 13, y: 2), screen: .zero, timestamp: 0.01)
        XCTAssertEqual(fixture.offset(), 10)
        surface.cancelInput()
        XCTAssertEqual(fixture.offset(), 0)
        XCTAssertNil(surface.gestureTracking)
        XCTAssertEqual(fixture.events.last?.event.phase, .cancelled)
        XCTAssertNil(fixture.lastInvocation)
        let scene = surface.scene
        let slot = surface.layout.core.rootHandle.slot
        XCTAssertTrue(ShellLayerScene.engineQueue
            .sync { scene.gestureLayers[slot]?.layer.animationKeys()?.isEmpty != false })
    }

    func testNativeOnlyTrackSettlesAfterReleaseWithoutInvokingLuau() throws {
        let fixture = try Fixture("return ui.box{w=40,h=20,gesture={axis='x',commit={distance=20},track={dx={0,20}}}}")
        let surface = fixture.surface
        surface.press(at: CGPoint(x: 3, y: 2), timestamp: 0)
        surface.drag(to: CGPoint(x: 28, y: 2), screen: .zero, timestamp: 0.01)
        XCTAssertEqual(fixture.offset(), 20)
        XCTAssertTrue(fixture.events.isEmpty)
        surface.release(at: CGPoint(x: 28, y: 2), timestamp: 0.02)
        XCTAssertEqual(fixture.offset(), 0)
        XCTAssertTrue(fixture.events.isEmpty)
        XCTAssertNil(surface.gestureTracking)
    }

    func testOlderAcknowledgementCannotSettleNewCapturedGesture() throws {
        let fixture = try Fixture(body)
        let surface = fixture.surface
        surface.press(at: CGPoint(x: 3, y: 2), timestamp: 0)
        surface.drag(to: CGPoint(x: 28, y: 2), screen: .zero, timestamp: 0.01)
        surface.release(at: CGPoint(x: 28, y: 2), timestamp: 0.02)
        let first = try XCTUnwrap(fixture.lastInvocation)
        surface.press(at: CGPoint(x: 3, y: 2), timestamp: 1)
        surface.drag(to: CGPoint(x: 13, y: 2), screen: .zero, timestamp: 1.01)
        XCTAssertEqual(fixture.offset(), 10)
        surface.acknowledgeGesture(through: first)
        XCTAssertEqual(fixture.offset(), 10)
        XCTAssertEqual(surface.gestureTracking?.holding, false)
        surface.cancelInput()
    }

    func testRecipeChangesDoNotRebindCapturedGesture() throws {
        let fixture =
            try Fixture(
                "return ui.box{key='root',w=40,h=20,gesture={axis='x',commit={distance=20},track={dx={0,ctx.data.seconds==0 and 20 or 100}}},onGesture=function() end}"
            )
        let surface = fixture.surface
        surface.press(at: CGPoint(x: 3, y: 2), timestamp: 0)
        surface.drag(to: CGPoint(x: 13, y: 2), screen: .zero, timestamp: 0.01)
        fixture.render(1)
        surface.drag(to: CGPoint(x: 18, y: 2), screen: .zero, timestamp: 0.02)
        XCTAssertEqual(fixture.offset(), 15)
        surface.cancelInput()
        surface.press(at: CGPoint(x: 3, y: 2), timestamp: 1)
        surface.drag(to: CGPoint(x: 13, y: 2), screen: .zero, timestamp: 1.01)
        XCTAssertEqual(fixture.offset(), 50)
        surface.cancelInput()
    }

    func testContainerTrackingPreservesItsMaskedSubtree() throws {
        let fixture =
            try Fixture(
                "return ui.stack{w=40,h=20,gesture={axis='x',commit={distance=20},track={dx={0,20}}},onGesture=function() end,ui.path{d='M0 0 L40 0 L40 20 L0 20 Z',viewBox={0,0,40,20},w=40,h=20,mask=true},ui.box{w=40,h=20,fill='accent'}}"
            )
        let surface = fixture.surface
        let slot = surface.layout.core.rootHandle.slot
        surface.press(at: CGPoint(x: 3, y: 2), timestamp: 0)
        surface.drag(to: CGPoint(x: 13, y: 2), screen: .zero, timestamp: 0.01)
        let scene = surface.scene
        let valid = ShellLayerScene.engineQueue.sync {
            guard let content = scene.layers[slot], let wrapper = scene.gestureLayers[slot]?.layer else { return false }
            return content.mask != nil && content.superlayer === wrapper && wrapper.superlayer === scene.container
                && wrapper.transform.m41 == 10 && scene.displayedLayer(slot) === wrapper
        }
        XCTAssertTrue(valid)
        surface.cancelInput()
    }
}
