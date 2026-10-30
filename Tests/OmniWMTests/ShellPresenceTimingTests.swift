// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellPresenceTimingTests: XCTestCase {
    func testTrailingCenterAnchorIsFixedByTheAppearanceTransform() throws {
        let scene = ShellLayerScene(container: CALayer(), scale: 2)
        let state = try ShellLayerScene.engineQueue.sync {
            let layer = CALayer()
            layer.bounds.size = CGSize(width: 80, height: 40)
            let appearance = ShellPresence(
                opacity: 0, scale: 0.05, offset: .zero,
                animation: ShellAnimation(motion: .ease, speed: 1), anchor: CGPoint(x: 1, y: 0.5)
            )
            scene.setPresence(0, appear: appearance, exit: nil)
            scene.applyAppearance(0, to: layer, preset: nil, animated: true)
            let group = try XCTUnwrap(layer.animation(forKey: ShellLayerScene.appearanceKey) as? CAAnimationGroup)
            let transform = try XCTUnwrap(group.animations?.compactMap { $0 as? CABasicAnimation }
                .first { $0.keyPath == "transform" })
            return (try XCTUnwrap(transform.fromValue as? NSValue).caTransform3DValue, layer.transform)
        }
        XCTAssertEqual(80 * state.0.m11 + 20 * state.0.m21 + state.0.m41, 80, accuracy: 0.0001)
        XCTAssertEqual(80 * state.0.m12 + 20 * state.0.m22 + state.0.m42, 20, accuracy: 0.0001)
        XCTAssertEqual(state.0.m11, 0.05, accuracy: 0.0001)
        XCTAssertEqual(state.0.m41, 76, accuracy: 0.0001)
        XCTAssertTrue(CATransform3DIsIdentity(state.1))
    }

    func testDelayUsesAnimationSpeedAndHoldsTheFromStateWithFinalModelValues() throws {
        for speed in [1.0, 2.0] {
            let presence = ShellPresence(
                opacity: 0, scale: 0.5, offset: CGPoint(x: 3, y: 4),
                animation: ShellAnimation(motion: .ease(seconds: 0.4), speed: speed), delay: 0.2
            )
            let group = try XCTUnwrap(presence.group(
                fromOpacity: 0, toOpacity: 0.75,
                fromTransform: presence.transform(from: CATransform3DIdentity, size: CGSize(width: 80, height: 40)),
                toTransform: CATransform3DIdentity, at: 100
            ))
            XCTAssertEqual(group.beginTime, 100 + 0.2 / speed, accuracy: 0.000001)
            XCTAssertEqual(group.duration, 0.4 / speed, accuracy: 0.000001)
            XCTAssertEqual(group.fillMode, .backwards)
            XCTAssertTrue(group.isRemovedOnCompletion)
            let opacity = try XCTUnwrap(group.animations?.compactMap { $0 as? CABasicAnimation }
                .first { $0.keyPath == "opacity" })
            XCTAssertEqual((opacity.fromValue as? NSNumber)?.floatValue, 0)
            XCTAssertEqual((opacity.toValue as? NSNumber)?.floatValue, 0.75)
        }
    }

    func testDelayedAppearanceUsesLayerLocalTimeWithoutChangingTheModel() throws {
        let scene = ShellLayerScene(container: CALayer(), scale: 2)
        let values = try ShellLayerScene.engineQueue.sync {
            let layer = CALayer()
            layer.speed = 2
            layer.timeOffset = 5
            layer.bounds.size = CGSize(width: 80, height: 40)
            layer.opacity = 0.75
            let lower = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.1
            scene.setPresence(0, appear: ShellPresence(
                opacity: 0, scale: 0.5, offset: .zero,
                animation: ShellAnimation(motion: .ease, speed: 2), delay: 0.2
            ), exit: nil)
            scene.applyAppearance(0, to: layer, preset: nil, animated: true)
            let upper = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.1
            let group = try XCTUnwrap(layer.animation(forKey: ShellLayerScene.appearanceKey) as? CAAnimationGroup)
            return (group.beginTime, lower, upper, group.fillMode, layer.opacity, layer.transform)
        }
        XCTAssertGreaterThanOrEqual(values.0, values.1)
        XCTAssertLessThanOrEqual(values.0, values.2)
        XCTAssertEqual(values.3, .backwards)
        XCTAssertEqual(values.4, 0.75)
        XCTAssertTrue(CATransform3DIsIdentity(values.5))
    }

    func testWirePresenceReachesRuntimeAnchorDelayAndRevealParser() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.stack{key='root',w=100,h=50,reveal={response=0.4,bounce=0.2},
                appear={scale=0.05,anchor={x=1,y=0.5},delay=0.2,animate='ease'},
                exit={opacity=0,anchor={x=0,y=0},delay=0.1,animate='ease'}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let text = ShellTextStore()
        text.ingest(wire: script.output)
        let surface = ShellWidgetSurface(
            scale: 2, resources: ShellResources(motion: MotionPolicy(animationsEnabled: true)), directories: []
        )
        XCTAssertTrue(surface.apply(script.output, text: text))
        let root = surface.layout.core.rootHandle
        let paint = surface.layout.core.paint(of: root)
        let appear = try XCTUnwrap(surface.presence(paint.appear, for: root))
        let exit = try XCTUnwrap(surface.presence(paint.exit, for: root))
        let reveal = try XCTUnwrap(surface.reveal(paint.reveal))
        XCTAssertEqual(appear.anchor, CGPoint(x: 1, y: 0.5))
        XCTAssertEqual(appear.delay, 0.2)
        XCTAssertEqual(exit.anchor, .zero)
        XCTAssertEqual(exit.delay, 0.1)
        XCTAssertEqual(reveal.response, 0.4)
        XCTAssertEqual(reveal.bounce, 0.2)
        XCTAssertNil(surface.reveal(0))
    }

    func testInsertionAnimationCommitSeamIsRecordedWithoutUsingTimeAsReadiness() throws {
        let scene = ShellLayerScene(container: CALayer(), scale: 2)
        scene.submit([.insert(slot: 0, parent: -1, kind: .box, after: -1)], animated: false)
        let state = try ShellLayerScene.engineQueue.sync {
            let layer = try XCTUnwrap(scene.layers[0])
            scene.setPresence(0, appear: ShellPresence(
                opacity: 0, scale: 0.05, offset: .zero,
                animation: ShellAnimation(motion: .ease, speed: 1), anchor: CGPoint(x: 1, y: 0.5), delay: 0.2
            ), exit: nil)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scene.applyFrame(0, CGRect(x: 0, y: 0, width: 80, height: 40), preset: nil, animated: true)
            let before = layer.animation(forKey: ShellLayerScene.appearanceKey) != nil
            CATransaction.commit()
            let after = layer.animation(forKey: ShellLayerScene.appearanceKey) != nil
            return (before, after, layer.opacity, layer.transform)
        }
        XCTAssertTrue(state.0)
        XCTAssertEqual(state.2, 1)
        XCTAssertTrue(CATransform3DIsIdentity(state.3))
        print("B5 detached insertion seam: beforeCommit=\(state.0) afterCommit=\(state.1)")
    }
}
