// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class ShellSpringContinuityTests: XCTestCase {
    func testSpringRecipeBuildsNativeSpringBeforeCurveParsing() throws {
        let motion = try XCTUnwrap(ShellMotion(recipe: "spring:0.31:0.22"))
        XCTAssertEqual(motion, .spring(response: 0.31, bounce: 0.22))
        let animation = try XCTUnwrap(ShellAnimation(motion: motion, speed: 2).make("opacity") as? CASpringAnimation)
        XCTAssertEqual(animation.perceptualDuration, 0.155, accuracy: 0.000001)
        XCTAssertEqual(animation.bounce, 0.22, accuracy: 0.000001)
        for invalid in ["spring:0:0", "spring:3:0", "spring:0.3:1", "spring:nan:0", "spring:0.3:0:x"] {
            XCTAssertNil(ShellMotion(recipe: invalid))
        }
    }

    func testRetargetCarriesPhysicalVelocityAndClampsNormalizedVelocity() throws {
        let scene = ShellLayerScene(container: CALayer(), scale: 2)
        let values = try ShellLayerScene.engineQueue.sync {
            let layer = CALayer()
            let motion = ShellAnimation(motion: .spring, speed: 1)
            let original = try XCTUnwrap(motion.make("position.x") as? CASpringAnimation)
            original.fromValue = 0
            original.toValue = 100
            original.initialVelocity = 0.5
            original.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - 0.03
            layer.add(original, forKey: "position.x")
            scene.add(motion, to: layer, "position.x", from: 45, to: 10)
            let replacement = try XCTUnwrap(layer.animation(forKey: "position.x") as? CASpringAnimation)
            let expected = ShellLayerScene.springVelocity(original, at: replacement.beginTime) / -35
            scene.add(motion, to: layer, "opacity", from: 0.999, to: 1, velocity: 100)
            let clamped = try XCTUnwrap(layer.animation(forKey: "opacity") as? CASpringAnimation)
            return (replacement.initialVelocity, expected, clamped.initialVelocity)
        }
        XCTAssertEqual(values.0, min(max(values.1, -20), 20), accuracy: 0.000001)
        XCTAssertNotEqual(values.0, 0)
        XCTAssertEqual(values.2, 20)
    }

    func testFrameSpringsUseIndependentScalarAxes() throws {
        let scene = ShellLayerScene(container: CALayer(), scale: 2)
        scene.submit([
            .insert(slot: 0, parent: -1, kind: .image, after: -1),
            .frame(slot: 0, rect: CGRect(x: 0, y: 0, width: 20, height: 30), animation: nil)
        ], animated: false)
        let state = ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            scene.applyFrame(
                0,
                CGRect(x: 10, y: 40, width: 50, height: 60),
                preset: ShellAnimation(motion: .spring, speed: 1),
                animated: true
            )
            let layer = scene.layers[0]
            let keys = layer?.animationKeys() ?? []
            let targets = ["position.x", "position.y", "bounds.size.width", "bounds.size.height"].map {
                (layer?.animation(forKey: $0) as? CASpringAnimation)?.toValue as? Double
            }
            return (keys, targets)
        }
        XCTAssertFalse(state.0.contains("position"))
        XCTAssertFalse(state.0.contains("bounds"))
        XCTAssertEqual(state.1, [10, 40, 50, 60])
    }

    func testFinishedSpringHasNoResidualVelocity() {
        let spring = CASpringAnimation(perceptualDuration: 0.3, bounce: 0.2)
        spring.fromValue = 0
        spring.toValue = 100
        spring.beginTime = 10
        spring.duration = spring.settlingDuration
        XCTAssertEqual(ShellLayerScene.springVelocity(spring, at: 10 + spring.duration + 1), 0)
        XCTAssertEqual(ShellLayerScene.springVelocity(spring, at: 9), 0)
    }
}
