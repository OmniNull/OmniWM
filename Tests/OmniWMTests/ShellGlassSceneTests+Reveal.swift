// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
private final class RevealSettlements {
    var values: [UInt64] = []
}

private struct OpenedReveal {
    let scene: ShellLayerScene
    let renderer: ShellOffscreenRenderer
    let plan: ShellReveal
}

private struct RevealRim {
    var left: CGFloat = 0
    var right: CGFloat = 0
    var top: CGFloat = 0
    var bottom: CGFloat = 0
}

@MainActor
extension ShellGlassSceneTests {
    private nonisolated static let card = CGRect(x: 80, y: 50, width: 160, height: 100)
    private nonisolated static let cardRadius: CGFloat = 20
    private nonisolated static let glassKeys = ["position", "bounds", "cornerRadius"]

    private func revealScene(native: Bool = true) -> ShellLayerScene {
        let layer = CALayer()
        layer.isGeometryFlipped = true
        layer.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        return ShellLayerScene(container: layer, scale: 1, glassNativeEnabled: native)
    }

    private func revealCommands(_ plan: ShellReveal?) -> [ShellLayerCommand] {
        var root = paint()
        root.reveal = ShellRevealRecipe("reveal:0.482:0.31")
        var shape = paint(radius: Self.cardRadius)
        shape.morph = ShellMorphRecipe(ShellRevealTests.glassMorph)
        var content = paint()
        content.morph = ShellMorphRecipe(ShellRevealTests.contentMorph)
        let commands: [ShellLayerCommand] = [
            .insert(
                slot: 0, parent: -1, kind: .group, after: -1,
                identity: ShellLayerIdentity(parent: .none, key: 7, kind: .group)
            ),
            .paint(slot: 0, root, animation: nil),
            .frame(slot: 0, rect: CGRect(x: 0, y: 0, width: 320, height: 200), animation: nil),
            .insert(slot: 1, parent: 0, kind: .glass, after: -1),
            .glass(
                slot: 1,
                ShellGlassContent(kind: .glass, recipe: recipe, shape: 0, paint: paint(), params: .zero),
                animation: nil
            ),
            .frame(slot: 1, rect: Self.card, animation: nil),
            .insert(slot: 2, parent: 1, kind: .shape, after: -1),
            .glass(
                slot: 2,
                ShellGlassContent(kind: .shape, recipe: "", shape: 0, paint: shape, params: .zero),
                animation: nil
            ),
            .frame(slot: 2, rect: CGRect(origin: .zero, size: Self.card.size), animation: nil),
            .insert(slot: 3, parent: 0, kind: .group, after: 1),
            .paint(slot: 3, content, animation: nil),
            .frame(slot: 3, rect: Self.card, animation: nil)
        ]
        return commands + (plan.map { [.reveal(slot: 0, token: 1, $0)] } ?? [])
    }

    private func opening(after delay: CFTimeInterval = 0) throws -> ShellReveal {
        try ShellReveal(begin: CACurrentMediaTime() + delay, progress: 0, target: 1, spring: ShellRevealTests.drip())
    }

    private nonisolated static func sampled(_ plan: ShellReveal, at time: CFTimeInterval) throws -> CGRect {
        let recipe = try XCTUnwrap(ShellMorphRecipe(ShellRevealTests.glassMorph))
        let state = plan.state(at: time)
        return recipe.shape(
            CGRect(origin: .zero, size: card.size), radius: cardRadius,
            progress: state.progress, velocity: state.velocity
        ).rect.offsetBy(dx: card.minX, dy: card.minY)
    }

    private nonisolated static func keyframed(_ plan: ShellReveal, at time: CFTimeInterval) throws -> CGRect {
        let samples = plan.samples
        let elapsed = time - plan.begin
        guard let upper = samples.firstIndex(where: { $0.time >= elapsed }), upper > 0 else {
            return try sampled(plan, at: time)
        }
        let from = try sampled(plan, at: plan.begin + samples[upper - 1].time)
        let to = try sampled(plan, at: plan.begin + samples[upper].time)
        let fraction = (elapsed - samples[upper - 1].time) / (samples[upper].time - samples[upper - 1].time)
        func mix(_ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            lower + (upper - lower) * fraction
        }
        return CGRect(
            x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
            width: mix(from.width, to.width), height: mix(from.height, to.height)
        )
    }

    private nonisolated static func silhouette(
        _ body: ShellGlassBody,
        _ renderer: ShellOffscreenRenderer,
        container: CALayer,
        at time: CFTimeInterval
    ) throws -> CGRect {
        body.sdfLayers.first?.isHidden = true
        let bytes = try renderer.render(paused: time)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.sdfLayers.first?.isHidden = false
        container.speed = 1
        container.timeOffset = 0
        CATransaction.commit()
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for row in 0 ..< 200 {
            for column in 0 ..< 320 where bytes[(row * 320 + column) * 4 + 3] > 8 {
                minX = min(minX, column)
                maxX = max(maxX, column)
                minY = min(minY, row)
                maxY = max(maxY, row)
            }
        }
        guard minX <= maxX else { return .null }
        return CGRect(x: minX, y: minY, width: maxX + 1 - minX, height: maxY + 1 - minY)
    }

    private nonisolated static func assertClose(
        _ actual: CGRect,
        _ expected: CGRect,
        rim: RevealRim = RevealRim(),
        line: UInt = #line
    ) {
        for (value, target) in [
            (actual.minX, expected.minX + rim.left), (actual.maxX, expected.maxX + rim.right),
            (actual.minY, expected.minY + rim.top), (actual.maxY, expected.maxY + rim.bottom)
        ] {
            XCTAssertEqual(value, target, accuracy: 1, line: line)
        }
    }

    private nonisolated static func rim(
        _ body: ShellGlassBody,
        _ renderer: ShellOffscreenRenderer,
        container: CALayer,
        at time: CFTimeInterval
    ) throws -> RevealRim {
        let drawn = try silhouette(body, renderer, container: container, at: time)
        let rim = RevealRim(
            left: drawn.minX - card.minX, right: drawn.maxX - card.maxX,
            top: drawn.minY - card.minY, bottom: drawn.maxY - card.maxY
        )
        XCTAssertTrue([rim.left, rim.right, rim.top, rim.bottom].allSatisfy { abs($0) <= 2 })
        return rim
    }

    private nonisolated static func keyframes(_ layer: CALayer, _ key: String) throws -> CAKeyframeAnimation {
        try XCTUnwrap(layer.animation(forKey: key) as? CAKeyframeAnimation, key)
    }

    private func openedScene() async throws -> OpenedReveal {
        let scene = revealScene()
        let renderer = try ShellLayerScene.engineQueue.sync {
            try ShellOffscreenRenderer(root: scene.container, width: 320, height: 200)
        }
        let plan = try opening()
        await apply(revealCommands(plan), to: scene, animated: true)
        return OpenedReveal(scene: scene, renderer: renderer, plan: plan)
    }

    private nonisolated static func frames(_ plan: ShellReveal) throws -> [(rect: CGRect, radius: CGFloat)] {
        let recipe = try XCTUnwrap(ShellMorphRecipe(ShellRevealTests.glassMorph))
        return plan.samples.map {
            recipe.shape(
                CGRect(origin: .zero, size: card.size), radius: cardRadius,
                progress: $0.progress, velocity: $0.velocity
            )
        }
    }

    func testRevealShapeKeyframesRunInLockstepFromClosedToTheLayoutGeometry() async throws {
        let opened = try await openedScene()
        let (scene, renderer, plan) = (opened.scene, opened.renderer, opened.plan)
        let frames = try Self.frames(plan)
        try ShellLayerScene.engineQueue.sync {
            let body = try Self.native(scene.glassBodies[1])
            let layers = body.lockstepLayers(2)
            XCTAssertEqual(layers.count, 5)
            for key in Self.glassKeys {
                let animations = try layers.map { try Self.keyframes($0, "omni.glass.\(key)") }
                for animation in animations {
                    XCTAssertEqual(animation.values as? [NSObject], animations[0].values as? [NSObject], key)
                    XCTAssertEqual(animation.keyTimes, animations[0].keyTimes, key)
                    XCTAssertEqual(animation.beginTime, animations[0].beginTime, key)
                    XCTAssertEqual(animation.duration, plan.duration, key)
                }
            }
            let positions = try XCTUnwrap(Self.keyframes(layers[0], "omni.glass.position").values as? [NSValue])
            let bounds = try XCTUnwrap(Self.keyframes(layers[0], "omni.glass.bounds").values as? [NSValue])
            let radii = try XCTUnwrap(Self.keyframes(layers[0], "omni.glass.cornerRadius").values as? [CGFloat])
            XCTAssertEqual(positions.count, frames.count)
            XCTAssertEqual(positions.first?.pointValue, CGPoint(x: 160, y: 50))
            XCTAssertEqual(bounds.first?.rectValue, .zero)
            XCTAssertEqual(positions.last?.pointValue, .zero)
            XCTAssertEqual(bounds.last?.rectValue, CGRect(origin: .zero, size: Self.card.size))
            XCTAssertEqual(radii.last, Self.cardRadius)
            for (index, frame) in frames.enumerated() {
                XCTAssertEqual(positions[index].pointValue, frame.rect.origin)
                XCTAssertLessThanOrEqual(radii[index], min(frame.rect.width, frame.rect.height) / 2 + 1e-9)
            }
        }
        withExtendedLifetime(renderer) {}
    }

    func testRevealCanvasCoversEverySampleAndTheSilhouetteFollowsTheSampler() async throws {
        let opened = try await openedScene()
        let (scene, renderer, plan) = (opened.scene, opened.renderer, opened.plan)
        let frames = try Self.frames(plan)
        try ShellLayerScene.engineQueue.sync {
            let body = try Self.native(scene.glassBodies[1])
            for layer in body.canvasLayers {
                let hold = try XCTUnwrap(layer.animation(forKey: "omni.glass.bounds") as? CABasicAnimation)
                let canvas = try XCTUnwrap(hold.fromValue as? NSValue).rectValue
                XCTAssertEqual(hold.toValue as? NSValue, hold.fromValue as? NSValue)
                XCTAssertEqual(hold.duration, plan.duration)
                XCTAssertTrue(hold.isRemovedOnCompletion)
                XCTAssertEqual(hold.fillMode, .removed)
                XCTAssertLessThan(canvas.minX, 0)
                XCTAssertTrue(frames.allSatisfy { canvas.insetBy(dx: -1e-6, dy: -1e-6).contains($0.rect) })
                let origin = try XCTUnwrap(layer.animation(forKey: "omni.glass.position") as? CABasicAnimation)
                XCTAssertEqual((origin.fromValue as? NSValue)?.pointValue, canvas.origin)
            }
            let rim = try Self.rim(body, renderer, container: scene.container, at: plan.end + 0.1)
            let early = plan.begin + 0.084
            let drawn = try Self.silhouette(body, renderer, container: scene.container, at: early)
            Self.assertClose(drawn, try Self.sampled(plan, at: early), rim: rim)
            Self.assertClose(drawn, try Self.keyframed(plan, at: early), rim: rim)
            XCTAssertGreaterThan(drawn.maxX, Self.card.maxX + 4)
            let late = plan.begin + 0.130
            let stretched = try Self.silhouette(body, renderer, container: scene.container, at: late)
            Self.assertClose(stretched, try Self.keyframed(plan, at: late), rim: rim)
            XCTAssertEqual(try Self.keyframed(plan, at: late).minX, try Self.sampled(plan, at: late).minX, accuracy: 2)
            XCTAssertLessThan(stretched.minX, Self.card.minX - 4)
        }
        withExtendedLifetime(renderer) {}
    }

    func testRevealGroupKeyframesScaleAboutTheAnchorAndCutOpacityAtTwoPercent() async throws {
        let scene = revealScene()
        let renderer = try ShellLayerScene.engineQueue.sync {
            try ShellOffscreenRenderer(root: scene.container, width: 320, height: 200)
        }
        let settlements = RevealSettlements()
        let settled: @MainActor @Sendable (Int32, UInt64) -> Void = { _, token in settlements.values.append(token) }
        ShellLayerScene.engineQueue.sync { scene.presence.onRevealSettled = settled }
        let plan = try opening(after: 10)
        await apply(revealCommands(plan), to: scene, animated: true)
        let recipe = try XCTUnwrap(ShellMorphRecipe(ShellRevealTests.contentMorph))
        let samples = plan.samples
        XCTAssertLessThanOrEqual(samples[0].progress, 0.02)
        XCTAssertTrue(samples.contains { $0.progress > 0.02 && $0.progress < 0.625 })
        let completion = try ShellLayerScene.engineQueue.sync {
            let layer = try XCTUnwrap(scene.layers[3])
            let transforms = try XCTUnwrap(Self.keyframes(layer, ShellLayerScene.revealTransformKey)
                .values as? [NSValue])
            let opacities = try XCTUnwrap(Self.keyframes(layer, ShellLayerScene.revealOpacityKey).values as? [Float])
            XCTAssertEqual(transforms.count, samples.count)
            for (index, sample) in samples.enumerated() {
                let transform = transforms[index].caTransform3DValue
                XCTAssertEqual(transform.m11, recipe.stop(at: sample.progress).scale, accuracy: 1e-9)
                XCTAssertEqual(160 * transform.m11 + 50 * transform.m21 + transform.m41, 160, accuracy: 1e-6)
                XCTAssertEqual(160 * transform.m12 + 50 * transform.m22 + transform.m42, 50, accuracy: 1e-6)
                if sample.progress <= 0.02 { XCTAssertEqual(opacities[index], 0) }
                if sample.progress >= 0.0201 { XCTAssertEqual(opacities[index], 1) }
            }
            let animations = [layer, scene.glassBodies[1]?.lockstepLayers(2).first].compactMap(\.self)
                .flatMap { target in
                    (target.animationKeys() ?? []).compactMap { target.animation(forKey: $0) }
                }
            return try XCTUnwrap(animations.lazy.compactMap { $0.delegate as? ShellManipulationCompletion }.first)
        }
        completion.completion(false)
        await drain()
        XCTAssertEqual(settlements.values, [])
        completion.completion(true)
        completion.completion(true)
        await drain()
        XCTAssertEqual(settlements.values, [1])
        withExtendedLifetime(renderer) {}
    }

    func testRevealRemovalPlaysToClosedFromTheCurrentStateAndRetainsUntilCompletion() async throws {
        let scene = revealScene()
        let renderer = try ShellLayerScene.engineQueue.sync {
            try ShellOffscreenRenderer(root: scene.container, width: 320, height: 200)
        }
        let plan = try opening()
        await apply(revealCommands(plan), to: scene, animated: true)
        let (body, content) = try ShellLayerScene.engineQueue.sync {
            try (Self.native(scene.glassBodies[1]), XCTUnwrap(scene.layers[3]))
        }
        let time = plan.begin + 0.1
        let closing = plan.retargeted(at: time, to: 0)
        await apply([.reveal(slot: 0, token: 0, closing), .remove(slot: 0)], to: scene, animated: true)
        try ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(scene.layers.isEmpty)
            XCTAssertEqual(scene.presence.retained.count, 1)
            let (token, retained) = try XCTUnwrap(scene.presence.retained.first)
            XCTAssertEqual(retained.pending.count, 1)
            XCTAssertTrue(retained.subtree.superlayer === scene.container)
            let position = try Self.keyframes(body.lockstepLayers(2)[0], "omni.glass.position")
            XCTAssertEqual(position.fillMode, .forwards)
            XCTAssertFalse(position.isRemovedOnCompletion)
            let positions = try XCTUnwrap(position.values as? [NSValue])
            let start = try Self.sampled(plan, at: time).offsetBy(dx: -Self.card.minX, dy: -Self.card.minY)
            XCTAssertEqual(positions.first?.pointValue.x ?? 0, start.minX, accuracy: 1e-9)
            XCTAssertEqual(positions.first?.pointValue.y ?? 0, start.minY, accuracy: 1e-9)
            XCTAssertEqual(positions.last?.pointValue, CGPoint(x: 160, y: 50))
            let scales = try XCTUnwrap(Self.keyframes(content, ShellLayerScene.revealTransformKey).values as? [NSValue])
            let recipe = try XCTUnwrap(ShellMorphRecipe(ShellRevealTests.contentMorph))
            XCTAssertEqual(
                scales.first?.caTransform3DValue.m11 ?? 0,
                recipe.stop(at: plan.state(at: time).progress).scale,
                accuracy: 1e-9
            )
            XCTAssertEqual(scales.last?.caTransform3DValue.m11, 0.05)
            let pending = try XCTUnwrap(retained.pending.first)
            scene.completePresenceAnimation(token, identifier: pending)
            XCTAssertTrue(scene.presence.retained.isEmpty)
            XCTAssertNil(retained.subtree.superlayer)
            scene.completePresenceAnimation(token, identifier: pending)
            XCTAssertTrue(scene.presence.retained.isEmpty)
        }
        withExtendedLifetime(renderer) {}
    }

    func testReinsertionDuringACloseContinuesTheRenderedWidth() async throws {
        let scene = revealScene()
        let renderer = try ShellLayerScene.engineQueue.sync {
            try ShellOffscreenRenderer(root: scene.container, width: 320, height: 200)
        }
        let plan = try opening()
        await apply(revealCommands(plan), to: scene, animated: true)
        let (retiring, rim) = try ShellLayerScene.engineQueue.sync {
            let body = try Self.native(scene.glassBodies[1])
            return try (body, Self.rim(body, renderer, container: scene.container, at: plan.end + 0.1))
        }
        let closing = plan.retargeted(at: plan.begin + 0.25, to: 0)
        await apply([.reveal(slot: 0, token: 0, closing), .remove(slot: 0)], to: scene, animated: true)
        let time = closing.begin + 0.1
        let before = try ShellLayerScene.engineQueue.sync {
            try Self.silhouette(retiring, renderer, container: scene.container, at: time)
        }
        Self.assertClose(before, try Self.keyframed(closing, at: time), rim: rim)
        let reopened = closing.retargeted(at: time, to: 1)
        await apply(revealCommands(reopened), to: scene, animated: true)
        try ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(scene.presence.retained.isEmpty)
            let body = try Self.native(scene.glassBodies[1])
            let after = try Self.silhouette(body, renderer, container: scene.container, at: time)
            XCTAssertEqual(after.width, before.width, accuracy: 1)
            XCTAssertEqual(after.minX, before.minX, accuracy: 1)
            XCTAssertGreaterThan(before.width, 20)
        }
        withExtendedLifetime(renderer) {}
    }

    func testFallbackBodyMasksRunTheSameKeyframesAndCoverTheStretchedSilhouette() async throws {
        let scene = revealScene(native: false)
        let renderer = try ShellLayerScene.engineQueue.sync {
            try ShellOffscreenRenderer(root: scene.container, width: 320, height: 200)
        }
        let plan = try opening()
        await apply(revealCommands(plan), to: scene, animated: true)
        try ShellLayerScene.engineQueue.sync {
            let body = try XCTUnwrap(scene.glassBodies[1])
            XCTAssertFalse(body.nativeAvailable)
            let layers = body.lockstepLayers(2)
            XCTAssertEqual(layers.count, 2)
            for key in Self.glassKeys {
                let animations = try layers.map { try Self.keyframes($0, "omni.glass.\(key)") }
                XCTAssertEqual(animations[0].values as? [NSObject], animations[1].values as? [NSObject], key)
                XCTAssertEqual(animations[0].beginTime, animations[1].beginTime, key)
            }
            let time = plan.begin + 0.130
            let expected = try Self.keyframed(plan, at: time)
            let rim = try Self.rim(body, renderer, container: scene.container, at: plan.end + 0.1)
            let drawn = try Self.silhouette(body, renderer, container: scene.container, at: time)
            Self.assertClose(drawn, expected, rim: rim)
            XCTAssertLessThan(drawn.minX, Self.card.minX - 4)
        }
        withExtendedLifetime(renderer) {}
    }

    func testRevealWithoutAnimationAddsNoKeyframesAndStillReportsSettled() async throws {
        let scene = revealScene()
        let settlements = RevealSettlements()
        let settled: @MainActor @Sendable (Int32, UInt64) -> Void = { _, token in settlements.values.append(token) }
        ShellLayerScene.engineQueue.sync { scene.presence.onRevealSettled = settled }
        await apply(revealCommands(try opening()), to: scene, animated: false)
        try ShellLayerScene.engineQueue.sync {
            let body = try XCTUnwrap(scene.glassBodies[1])
            for layer in body.lockstepLayers(2) + body.canvasLayers {
                XCTAssertTrue(Self.glassKeys.allSatisfy { layer.animation(forKey: "omni.glass.\($0)") == nil })
            }
            XCTAssertEqual(body.lockstepLayers(2).first?.bounds.size, Self.card.size)
            let content = try XCTUnwrap(scene.layers[3])
            XCTAssertNil(content.animation(forKey: ShellLayerScene.revealTransformKey))
            XCTAssertEqual(content.opacity, 1)
        }
        await drain()
        XCTAssertEqual(settlements.values, [1])
    }

    private func drain() async {
        ShellLayerScene.engineQueue.sync {}
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
