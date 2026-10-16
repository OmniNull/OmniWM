// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellPresenceTests: XCTestCase {
    func testAppearanceUsesRelativeTargetsAndPreservesTheModelTransform() throws {
        let scene = ShellLayerScene(container: CALayer(), scale: 2)
        let appearance = recipe(opacity: 0.25, scale: 0.5, offset: CGPoint(x: 8, y: -4))
        let (group, modelOpacity, modelTransform, initialTransform) = ShellLayerScene.engineQueue.sync {
            let layer = CALayer()
            layer.bounds = CGRect(x: 0, y: 0, width: 80, height: 40)
            layer.opacity = 0.6
            layer.transform = CATransform3DRotate(CATransform3DMakeScale(1.2, 1.2, 1), 0.3, 0, 0, 1)
            let target = layer.transform
            scene.setPresence(0, appear: appearance, exit: nil)
            scene.applyAppearance(0, to: layer, preset: nil, animated: true)
            return (
                layer.animation(forKey: ShellLayerScene.appearanceKey) as? CAAnimationGroup,
                layer.opacity,
                layer.transform,
                appearance.transform(from: target, size: layer.bounds.size)
            )
        }
        let animations = try XCTUnwrap(group?.animations?.compactMap { $0 as? CABasicAnimation })
        let opacity = try XCTUnwrap(animations.first { $0.keyPath == "opacity" })
        let transform = try XCTUnwrap(animations.first { $0.keyPath == "transform" })
        XCTAssertEqual((opacity.fromValue as? NSNumber)?.floatValue ?? -1, 0.15, accuracy: 0.0001)
        XCTAssertEqual((opacity.toValue as? NSNumber)?.floatValue ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(modelOpacity, 0.6)
        XCTAssertTrue(CATransform3DEqualToTransform(
            try XCTUnwrap(transform.fromValue as? NSValue).caTransform3DValue, initialTransform
        ))
        XCTAssertTrue(CATransform3DEqualToTransform(
            try XCTUnwrap(transform.toValue as? NSValue).caTransform3DValue, modelTransform
        ))
    }

    func testNativeCompletionRemovesRetainedSubtreeEvenWhenExitEndsVisible() throws {
        let container = CALayer()
        let scene = ShellLayerScene(container: container, scale: 2)
        let state = try ShellLayerScene.engineQueue.sync {
            let wrapper = CALayer()
            let layer = CALayer()
            let child = CALayer()
            container.addSublayer(wrapper)
            wrapper.addSublayer(layer)
            layer.addSublayer(child)
            layer.bounds = CGRect(x: 0, y: 0, width: 80, height: 40)
            layer.opacity = 0.6
            scene.layers[0] = layer
            scene.insertPresence(0, identity: identity(1))
            scene.setPresence(0, appear: nil, exit: recipe(opacity: 0.5, scale: 0.8))
            scene.retirePresence(0, subtree: wrapper, animated: true)
            scene.forgetPresence(0)
            scene.layers.removeValue(forKey: 0)
            let retained = try XCTUnwrap(scene.presence.retained.values.first)
            XCTAssertTrue(retained.subtree === wrapper)
            XCTAssertTrue(retained.animatedLayer === layer)
            XCTAssertTrue(child.superlayer === layer)
            XCTAssertTrue(wrapper.superlayer === container)
            XCTAssertEqual(layer.opacity, 0.3)
            XCTAssertNil(scene.layers[0])
            return (retained.completion, wrapper)
        }
        state.0.animationDidStop(CAAnimation(), finished: true)
        let cleaned = ShellLayerScene.engineQueue.sync {
            (scene.presence.retained.isEmpty, state.1.superlayer == nil)
        }
        XCTAssertTrue(cleaned.0)
        XCTAssertTrue(cleaned.1)
    }

    func testKeyedReinsertionCancelsOldExitAndStaleCompletionCannotRemoveReplacement() throws {
        let container = CALayer()
        let scene = ShellLayerScene(container: container, scale: 2)
        let state = try ShellLayerScene.engineQueue.sync {
            let old = CALayer()
            old.bounds.size = CGSize(width: 20, height: 20)
            container.addSublayer(old)
            scene.layers[0] = old
            scene.insertPresence(0, identity: identity(5))
            scene.setPresence(0, appear: nil, exit: recipe(opacity: 0))
            scene.retirePresence(0, subtree: old, animated: true)
            let oldCompletion = try XCTUnwrap(scene.presence.retained.values.first?.completion)
            scene.forgetPresence(0)
            let replacement = CALayer()
            replacement.bounds.size = old.bounds.size
            container.addSublayer(replacement)
            scene.layers[0] = replacement
            scene.insertPresence(0, identity: identity(5))
            XCTAssertNil(old.superlayer)
            XCTAssertTrue(scene.presence.retained.isEmpty)
            scene.setPresence(0, appear: nil, exit: recipe(opacity: 0))
            scene.retirePresence(0, subtree: replacement, animated: true)
            let next = try XCTUnwrap(scene.presence.retained.values.first)
            return (oldCompletion, next.completion, replacement)
        }
        state.0.animationDidStop(CAAnimation(), finished: true)
        let survives = ShellLayerScene.engineQueue.sync {
            scene.presence.retained.count == 1 && state.2.superlayer === container
        }
        XCTAssertTrue(survives)
        state.1.animationDidStop(CAAnimation(), finished: false)
        XCTAssertTrue(ShellLayerScene.engineQueue.sync { scene.presence.retained.isEmpty })
    }

    func testRecycledSlotAndParentGenerationCannotCancelAnotherExit() throws {
        let container = CALayer()
        let scene = ShellLayerScene(container: container, scale: 2)
        let count = ShellLayerScene.engineQueue.sync {
            for (key, generation) in [(UInt64(5), UInt32(1)), (6, 1), (5, 2)] {
                let layer = CALayer()
                layer.bounds.size = CGSize(width: 20, height: 20)
                container.addSublayer(layer)
                scene.layers[0] = layer
                scene.insertPresence(0, identity: identity(key, parentGeneration: generation))
                scene.setPresence(0, appear: nil, exit: recipe(opacity: 0))
                scene.retirePresence(0, subtree: layer, animated: true)
                scene.forgetPresence(0)
            }
            let count = scene.presence.retained.count
            for token in Array(scene.presence.retained.keys) { scene.finishPresenceExit(token) }
            return count
        }
        XCTAssertEqual(count, 3)
    }

    func testImmediateAndReducedMotionExitsDoNotRetainLayers() {
        let container = CALayer()
        let scene = ShellLayerScene(container: container, scale: 2)
        let retained = ShellLayerScene.engineQueue.sync {
            for animated in [false, true] {
                let layer = CALayer()
                container.addSublayer(layer)
                scene.layers[0] = layer
                scene.setPresence(0, appear: nil, exit: ShellPresence(
                    opacity: 0, scale: 0.8, offset: .zero, animation: animated ? nil : .init(motion: .spring, speed: 1)
                ))
                scene.retirePresence(0, subtree: layer, animated: animated)
                XCTAssertNil(layer.superlayer)
            }
            return scene.presence.retained.count
        }
        XCTAssertEqual(retained, 0)
    }

    func testRecipeUpdateDoesNotReplayAppearanceAndControlsNextRemoval() throws {
        let container = CALayer()
        let scene = ShellLayerScene(container: container, scale: 2)
        let target = try ShellLayerScene.engineQueue.sync {
            let layer = CALayer()
            container.addSublayer(layer)
            scene.layers[0] = layer
            scene.setPresence(0, appear: recipe(opacity: 0), exit: recipe(opacity: 0.25))
            XCTAssertNil(layer.animation(forKey: ShellLayerScene.appearanceKey))
            scene.setPresence(0, appear: recipe(opacity: 0.5), exit: recipe(opacity: 0.75))
            XCTAssertNil(layer.animation(forKey: ShellLayerScene.appearanceKey))
            scene.retirePresence(0, subtree: layer, animated: true)
            let target = layer.opacity
            let token = try XCTUnwrap(scene.presence.retained.keys.first)
            scene.finishPresenceExit(token)
            return target
        }
        XCTAssertEqual(target, 0.75)
    }

    func testAppearanceKeepsTheSuppliedMultiSegmentCurveEndpoints() throws {
        let curve = try XCTUnwrap(ShellCurve(points: [0.1, 0, 0.4, 0.5, 0.5, 0.5, 0.6, 0.5, 0.9, 1, 1, 1]))
        let presence = ShellPresence(
            opacity: 0.25, scale: 1, offset: .zero,
            animation: ShellAnimation(motion: .ease(seconds: 0.4), speed: 1, curve: curve)
        )
        let animation = try XCTUnwrap(presence.group(
            fromOpacity: 0.2, toOpacity: 0.8,
            fromTransform: CATransform3DIdentity, toTransform: CATransform3DIdentity
        )?.animations?.first as? CAKeyframeAnimation)
        let values = try XCTUnwrap(animation.values as? [NSNumber])
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values.first?.doubleValue ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(values[1].doubleValue, 0.5, accuracy: 0.0001)
        XCTAssertEqual(values.last?.doubleValue ?? -1, 0.8, accuracy: 0.0001)
    }

    func testExplicitResetClearsAllOutgoingOwnershipAndIgnoresLaterCompletion() {
        let container = CALayer()
        let scene = ShellLayerScene(container: container, scale: 2)
        let completions = ShellLayerScene.engineQueue.sync {
            for slot in Int32(0) ... 1 {
                let layer = CALayer()
                layer.bounds.size = CGSize(width: 20, height: 20)
                container.addSublayer(layer)
                scene.layers[slot] = layer
                scene.insertPresence(slot, identity: identity(UInt64(slot + 1)))
                scene.setPresence(slot, appear: nil, exit: recipe(opacity: 0))
                scene.retirePresence(slot, subtree: layer, animated: true)
                scene.forgetPresence(slot)
                scene.layers.removeValue(forKey: slot)
            }
            XCTAssertEqual(scene.presence.retained.count, 2)
            return scene.presence.retained.values.map(\.completion)
        }
        scene.submit([.clearExits], animated: false)
        let cleared = ShellLayerScene.engineQueue.sync {
            scene.presence.retained.isEmpty && scene.presence.retainedByIdentity.isEmpty
                && container.sublayers?.isEmpty != false
        }
        XCTAssertTrue(cleared)
        for completion in completions { completion.animationDidStop(CAAnimation(), finished: false) }
        XCTAssertTrue(ShellLayerScene.engineQueue.sync { scene.presence.retained.isEmpty })
    }

    func testHiddenSceneClearsPreviousExitsAndDoesNotRetainNewRemovals() {
        let container = CALayer()
        let scene = ShellLayerScene(container: container, scale: 2)
        ShellLayerScene.engineQueue.sync {
            let layer = CALayer()
            layer.bounds.size = CGSize(width: 20, height: 20)
            container.addSublayer(layer)
            scene.layers[0] = layer
            scene.setPresence(0, appear: nil, exit: recipe(opacity: 0))
            scene.retirePresence(0, subtree: layer, animated: true)
            scene.forgetPresence(0)
            scene.layers.removeValue(forKey: 0)
            XCTAssertEqual(scene.presence.retained.count, 1)
        }
        scene.submit([.visibility(false)], animated: false)
        ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(scene.presence.retained.isEmpty)
            let layer = CALayer()
            layer.bounds.size = CGSize(width: 20, height: 20)
            container.addSublayer(layer)
            scene.layers[1] = layer
            scene.setPresence(1, appear: nil, exit: recipe(opacity: 0))
        }
        scene.submit([.remove(slot: 1)], animated: true)
        XCTAssertTrue(ShellLayerScene.engineQueue.sync {
            scene.presence.retained.isEmpty && container.sublayers?.isEmpty != false
        })
    }

    private nonisolated func identity(_ key: UInt64, parentGeneration: UInt32 = 1) -> ShellLayerIdentity {
        ShellLayerIdentity(parent: ElementHandle(slot: 9, generation: parentGeneration), key: key, kind: .box)
    }

    private nonisolated func recipe(
        opacity: Float = 1,
        scale: CGFloat = 1,
        offset: CGPoint = .zero
    ) -> ShellPresence {
        ShellPresence(
            opacity: opacity,
            scale: scale,
            offset: offset,
            animation: ShellAnimation(motion: .ease, speed: 1)
        )
    }
}
