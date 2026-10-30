// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellPulseTests: XCTestCase {
    private var renderers: [ShellOffscreenRenderer] = []

    private func recipe(_ fields: String = "0,30,0:0,0.2,0:0,6,0:0,-4,0", key: UInt64 = 1) throws -> ShellPulseRecipe {
        try XCTUnwrap(ShellPulseRecipe("pulse:\(key):1:\(fields)"))
    }

    private func paint(_ pulse: ShellPulseRecipe? = nil, scale: CGFloat = 1) -> ShellLayerPaint {
        ShellLayerPaint(
            fill: CGColor(gray: 1, alpha: 1), border: nil, borderWidth: 0, radius: 0,
            opacity: 1, scale: scale, shadow: nil, shadowRadius: 0, pulse: pulse
        )
    }

    private func submit(_ commands: [ShellLayerCommand], to scene: ShellLayerScene, animated: Bool = true) {
        scene.submit(commands, animated: animated)
        ShellLayerScene.engineQueue.sync {}
    }

    private func scene(_ pulse: ShellPulseRecipe? = nil, animated: Bool = true) throws -> ShellLayerScene {
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        root.isGeometryFlipped = true
        root.speed = 0
        root.timeOffset = 1000
        let scene = ShellLayerScene(container: root, scale: 1)
        renderers.append(try ShellLayerScene.engineQueue.sync {
            try ShellOffscreenRenderer(root: root, width: 256, height: 256)
        })
        submit([
            .insert(slot: 0, parent: -1, kind: .box, after: -1),
            .frame(slot: 0, rect: CGRect(x: 30, y: 40, width: 80, height: 20), animation: nil),
            .paint(slot: 0, paint(pulse), animation: nil)
        ], to: scene, animated: animated)
        return scene
    }

    private func animation(_ scene: ShellLayerScene, _ channel: String) throws -> CAKeyframeAnimation {
        try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(scene.layers[0]?.animation(forKey: "omni.pulse.\(channel)") as? CAKeyframeAnimation)
        }
    }

    func testEachDeclaredChannelUsesOneAdditiveTrackWithTheAuthoredTiming() throws {
        let scene = try scene(recipe())
        let keys = ShellLayerScene.engineQueue.sync { scene.layers[0]?.animationKeys() }
        XCTAssertEqual(Set(try XCTUnwrap(keys)), Set(ShellPulseRecipe.animationKeys))
        var begin: CFTimeInterval?
        for channel in ShellPulseRecipe.channels {
            let track = try animation(scene, channel)
            XCTAssertEqual(track.duration, 1)
            XCTAssertEqual(track.repeatCount, 0)
            XCTAssertTrue(track.isAdditive)
            XCTAssertTrue(track.isRemovedOnCompletion)
            XCTAssertEqual(track.calculationMode, .linear)
            XCTAssertEqual(track.values?.count, 3)
            if let begin { XCTAssertEqual(track.beginTime, begin) } else { begin = track.beginTime }
            XCTAssertEqual(track.keyPath, channel == "dx" ? "position.x" : channel == "dy" ? "position.y" : "transform")
        }
        let translation = try animation(scene, "dx")
        XCTAssertEqual(translation.values as? [Double], [0, 6, 0])
        let rotation = try animation(scene, "rotate")
        let turn = try XCTUnwrap(rotation.values?[1] as? NSValue).caTransform3DValue
        XCTAssertEqual(atan2(turn.m12, turn.m11) * 180 / .pi, 30, accuracy: 1e-9)
        let scale = try animation(scene, "scale")
        let enlarged = try XCTUnwrap(scale.values?[1] as? NSValue).caTransform3DValue
        XCTAssertEqual(enlarged.m11, 1.2, accuracy: 1e-9)
        XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(rotation.values?.last as? NSValue).caTransform3DValue))
        let model = ShellLayerScene.engineQueue.sync { scene.layers[0]?.transform }
        XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(model)))
    }

    func testSameKeyDoesNotRestartAndANewKeyReplacesAllPreviousChannels() throws {
        let scene = try scene(recipe())
        ShellLayerScene.engineQueue.sync {
            let sentinel = CAKeyframeAnimation(keyPath: "position.x")
            sentinel.duration = 7
            scene.layers[0]?.add(sentinel, forKey: "omni.pulse.dx")
        }
        submit([.paint(slot: 0, try paint(recipe(":::0,8,0")), animation: nil)], to: scene)
        XCTAssertEqual(try animation(scene, "dx").duration, 7)
        submit([.paint(slot: 0, try paint(recipe(":::0,8,0", key: 2)), animation: nil)], to: scene)
        let keys = ShellLayerScene.engineQueue.sync { scene.layers[0]?.animationKeys() }
        XCTAssertEqual(keys, ["omni.pulse.dy"])
        XCTAssertEqual(try animation(scene, "dy").values as? [Double], [0, 8, 0])
        submit([.paint(slot: 0, paint(), animation: nil)], to: scene)
        XCTAssertNil(ShellLayerScene.engineQueue.sync { scene.layers[0]?.animationKeys() })
        XCTAssertNil(ShellLayerScene.engineQueue.sync { scene.pulseKeys[0] })
    }

    func testReduceMotionConsumesTheKeyWithoutPlayingOrReplayingIt() throws {
        let pulse = try recipe()
        let scene = try scene(pulse, animated: false)
        XCTAssertNil(ShellLayerScene.engineQueue.sync { scene.layers[0]?.animationKeys() })
        submit([.paint(slot: 0, paint(pulse), animation: nil)], to: scene)
        XCTAssertNil(ShellLayerScene.engineQueue.sync { scene.layers[0]?.animationKeys() })
        submit([.paint(slot: 0, try paint(recipe(key: 2)), animation: nil)], to: scene)
        XCTAssertEqual(try animation(scene, "rotate").duration, 1)
        submit([.paint(slot: 0, try paint(recipe(key: 2)), animation: nil)], to: scene, animated: false)
        XCTAssertNil(ShellLayerScene.engineQueue.sync { scene.layers[0]?.animationKeys() })
    }

    func testRemovingARetainedSubtreeCancelsPulsesAndReinsertionCanReuseTheKey() throws {
        let scene = try scene(recipe())
        var parentPaint = try paint(recipe())
        parentPaint.exit = ShellPresence(
            opacity: 0, scale: 1, offset: .zero,
            animation: ShellAnimation(motion: .ease(seconds: 1), speed: 1)
        )
        submit([
            .paint(slot: 0, parentPaint, animation: nil),
            .insert(slot: 1, parent: 0, kind: .box, after: -1),
            .frame(slot: 1, rect: CGRect(x: 0, y: 0, width: 10, height: 10), animation: nil),
            .paint(slot: 1, try paint(recipe()), animation: nil)
        ], to: scene)
        let layers = ShellLayerScene.engineQueue.sync { [scene.layers[0], scene.layers[1]] }
        submit([.remove(slot: 0)], to: scene)
        ShellLayerScene.engineQueue.sync {
            XCTAssertEqual(scene.presence.retained.count, 1)
            XCTAssertTrue(scene.pulseKeys.isEmpty)
            for layer in layers {
                for key in ShellPulseRecipe.animationKeys { XCTAssertNil(layer?.animation(forKey: key)) }
            }
        }
        submit([
            .insert(slot: 0, parent: -1, kind: .box, after: -1),
            .frame(slot: 0, rect: CGRect(x: 0, y: 0, width: 20, height: 20), animation: nil),
            .paint(slot: 0, try paint(recipe()), animation: nil)
        ], to: scene)
        XCTAssertEqual(try animation(scene, "rotate").duration, 1)
        ShellLayerScene.engineQueue.sync { scene.finishAllPresenceExits() }
    }

    func testProductionPaintCommandCarriesPulseAndTextShadowOffset() throws {
        let widget = try ShellRenderedWidget(name: "pulse", source: """
        function render(ctx)
            return ui.text{key='text',text='Shadow',pulse={key=ctx.data.seconds or 1,duration=1,rotate={0,12,0}},
                shadow='#000000',shadowRadius=3,shadowOffset={x=2,y=7}}
        end
        """)
        widget.resources.motion.userAnimationsEnabled = true
        renderers.append(try ShellLayerScene.engineQueue.sync {
            try ShellOffscreenRenderer(root: widget.surface.scene.container, width: 256, height: 256)
        })
        ShellLayerScene.engineQueue.sync {
            widget.surface.scene.container.speed = 0
            widget.surface.scene.container.timeOffset = 1000
        }
        widget.render(ShellBarData(monitor: "test"))
        widget.set("seconds") { $0.number(2) }
        widget.render(ShellBarData(monitor: "test"))
        let handle = widget.surface.layout.core.rootHandle
        XCTAssertNotEqual(handle, .none)
        let scene = widget.surface.scene
        try ShellLayerScene.engineQueue.sync {
            let layer = try XCTUnwrap(scene.layers[handle.slot])
            XCTAssertEqual(layer.shadowOffset, CGSize(width: 2, height: 7))
            XCTAssertEqual(layer.shadowRadius, 3)
            XCTAssertEqual(layer.shadowOpacity, 1)
            XCTAssertNotNil(layer.contents)
            XCTAssertNotNil(layer.animation(forKey: "omni.pulse.rotate"))
            XCTAssertGreaterThan(layer.bounds.width, 0)
        }
    }

    func testRecipeRejectsANonNeutralLastSample() {
        XCTAssertNil(ShellPulseRecipe("pulse:1:1:0,12:::"))
        XCTAssertNil(ShellPulseRecipe("pulse:1:1:::0,3:"))
        XCTAssertNotNil(ShellPulseRecipe("pulse:1:1:12,0:::"))
        XCTAssertNil(ShellPulseRecipe("pulse:1:1:0,360,0:::"))
        XCTAssertNil(ShellPulseRecipe("pulse:1:1:0,-180,0:::"))
        XCTAssertNotNil(ShellPulseRecipe("pulse:1:1:0,90,179,0:::"))
    }

    func testQuarterTurnPulsesUseTheLocalBoundsMidpoint() throws {
        let scene = try scene()
        var paint = try paint(recipe())
        paint.quarter = true
        paint.rotation = .pi / 2
        paint.frameSize = CGSize(width: 20, height: 100)
        submit([
            .paint(slot: 0, paint, animation: nil),
            .frame(slot: 0, rect: CGRect(x: 30, y: 40, width: 20, height: 100), animation: nil)
        ], to: scene)
        for channel in ["rotate", "scale"] {
            let track = try animation(scene, channel)
            let value = try XCTUnwrap(track.values?[1] as? NSValue).caTransform3DValue
            XCTAssertEqual(value.m11 * 50 + value.m21 * 10 + value.m41, 50, accuracy: 1e-9)
            XCTAssertEqual(value.m12 * 50 + value.m22 * 10 + value.m42, 10, accuracy: 1e-9)
        }
    }

    func testPulseRemainsAdditiveDuringPresenceAndLaterPaintAnimation() throws {
        let scene = try scene()
        let renderer = try XCTUnwrap(renderers.first)
        var paint = try paint(recipe("0,30,0:::"))
        paint.appear = ShellPresence(
            opacity: 1, scale: 0.5, offset: .zero,
            animation: ShellAnimation(motion: .ease(seconds: 1), speed: 1)
        )
        submit([
            .remove(slot: 0),
            .insert(slot: 0, parent: -1, kind: .box, after: -1),
            .paint(slot: 0, paint, animation: nil),
            .frame(slot: 0, rect: CGRect(x: 88, y: 122, width: 80, height: 12), animation: nil)
        ], to: scene)
        let duringPresence = try ShellLayerScene.engineQueue.sync { try renderer.render(paused: 1000.5) }
        XCTAssertEqual(moments(duringPresence).angle, 30, accuracy: 0.5)
        paint = try self.paint(recipe("0,30,0:::"), scale: 1.1)
        submit([
            .paint(slot: 0, paint, animation: ShellAnimation(motion: .ease(seconds: 1), speed: 1))
        ], to: scene)
        let duringPaint = try ShellLayerScene.engineQueue.sync { try renderer.render(paused: 1000.5) }
        XCTAssertEqual(moments(duringPaint).angle, 30, accuracy: 0.5)
    }

    func testRenderedPulseComposesRotationScaleAndOffsetsAndReturnsToTheModel() throws {
        let root = CALayer()
        let begin = CACurrentMediaTime()
        root.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        root.isGeometryFlipped = true
        root.speed = 0
        root.timeOffset = begin
        let scene = ShellLayerScene(container: root, scale: 1)
        let renderer = try ShellLayerScene.engineQueue.sync {
            try ShellOffscreenRenderer(root: root, width: 256, height: 256)
        }
        var paint = try paint(recipe(), scale: 1.2)
        paint.rotation = 20 * .pi / 180
        paint.frameSize = CGSize(width: 80, height: 12)
        submit([
            .insert(slot: 0, parent: -1, kind: .box, after: -1),
            .paint(slot: 0, paint, animation: nil),
            .frame(slot: 0, rect: CGRect(x: 88, y: 122, width: 80, height: 12), animation: nil)
        ], to: scene)
        for (elapsed, angle, factor, center) in [
            (0.0, 20.0, 1.2, CGPoint(x: 128, y: 128)),
            (0.5, 50.0, 1.44, CGPoint(x: 134, y: 124)),
            (0.9999, 20.006, 1.200048, CGPoint(x: 128.0012, y: 127.9992)),
            (1.001, 20.0, 1.2, CGPoint(x: 128, y: 128))
        ] {
            let bytes = try ShellLayerScene.engineQueue.sync { try renderer.render(paused: begin + elapsed) }
            let moments = moments(bytes)
            XCTAssertEqual(moments.angle, angle, accuracy: 0.5, "\(elapsed)")
            XCTAssertEqual(moments.center.x, center.x, accuracy: 0.5, "\(elapsed)")
            XCTAssertEqual(moments.center.y, center.y, accuracy: 0.5, "\(elapsed)")
            XCTAssertEqual(moments.area, 80 * 12 * factor * factor, accuracy: 12, "\(elapsed)")
        }
    }

    private func moments(_ bytes: [UInt8]) -> (angle: Double, center: CGPoint, area: Double) {
        var area = 0.0, x = 0.0, y = 0.0, xx = 0.0, yy = 0.0, xy = 0.0
        for row in 0 ..< 256 {
            for column in 0 ..< 256 {
                let alpha = Double(bytes[(row * 256 + column) * 4 + 3]) / 255
                let px = Double(column) + 0.5, py = Double(row) + 0.5
                area += alpha
                x += alpha * px
                y += alpha * py
                xx += alpha * px * px
                yy += alpha * py * py
                xy += alpha * px * py
            }
        }
        XCTAssertGreaterThan(area, 0)
        let center = CGPoint(x: x / max(area, 1), y: y / max(area, 1))
        let covariance = xy / max(area, 1) - center.x * center.y
        let variance = (xx - yy) / max(area, 1) - center.x * center.x + center.y * center.y
        return (atan2(2 * covariance, variance) * 90 / .pi, center, area)
    }
}
