// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellManipulationSceneTests: XCTestCase {
    private static let width = 256
    private static let height = 96
    static let home = CGRect(x: 8, y: 8, width: 40, height: 40)
    static let keys = ["transform.translation.x", "transform.translation.y", "transform.scale"]

    private func desk() throws -> ShellSpringDynamics.Parameters {
        try XCTUnwrap(ShellSpringDynamics.Parameters(
            ShellAnimation(motion: .spring(response: 0.363, bounce: 0.42), speed: 1)
        ))
    }

    func motion(
        from start: CGRect,
        velocity: ShellManipulationMotion.Velocity = .zero,
        to target: CGRect,
        begin: CFTimeInterval
    ) throws -> ShellManipulationMotion {
        try XCTUnwrap(ShellManipulationMotion(
            from: start,
            velocity: velocity,
            to: target,
            begin: begin,
            spring: desk()
        ))
    }

    func makeScene(
        at begin: CFTimeInterval,
        fill: CGColor = CGColor(gray: 1, alpha: 1)
    ) throws -> (ShellLayerScene, ShellOffscreenRenderer) {
        let container = CALayer()
        container.isGeometryFlipped = true
        container.frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        let scene = ShellLayerScene(container: container, scale: 1)
        let renderer = try ShellLayerScene.engineQueue.sync {
            try ShellOffscreenRenderer(root: container, width: Self.width, height: Self.height)
        }
        pause(scene, at: begin)
        submit([
            .insert(slot: 0, parent: -1, kind: .box, after: -1),
            .frame(slot: 0, rect: Self.home, animation: nil),
            .paint(
                slot: 0,
                ShellLayerPaint(
                    fill: fill, border: nil, borderWidth: 0, radius: 0,
                    opacity: 1, scale: 1, shadow: nil, shadowRadius: 0
                ),
                animation: nil
            )
        ], to: scene)
        return (scene, renderer)
    }

    func submit(_ commands: [ShellLayerCommand], to scene: ShellLayerScene) {
        scene.submit(commands, animated: false)
        ShellLayerScene.engineQueue.sync {}
    }

    func manipulate(
        _ scene: ShellLayerScene,
        _ presentation: ShellManipulationPresentation,
        token: UInt64 = 1,
        active: Bool = true
    ) {
        submit([.manipulation(slot: 0, token: token, presentation: presentation, active: active)], to: scene)
    }

    private func pause(_ scene: ShellLayerScene, at time: CFTimeInterval) {
        ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scene.container.speed = 0
            scene.container.timeOffset = time
            CATransaction.commit()
        }
    }

    private func rendered(_ renderer: ShellOffscreenRenderer, at time: CFTimeInterval) throws -> CGRect {
        let bytes = try ShellLayerScene.engineQueue.sync { try renderer.render(paused: time) }
        var rows = [Double](repeating: 0, count: Self.height)
        var columns = [Double](repeating: 0, count: Self.width)
        for row in 0 ..< Self.height {
            for column in 0 ..< Self.width {
                let alpha = Double(bytes[(row * Self.width + column) * 4 + 3]) / 255
                rows[row] += alpha
                columns[column] += alpha
            }
        }
        let width = try XCTUnwrap(rows.max())
        let height = try XCTUnwrap(columns.max())
        let left = try XCTUnwrap(columns.firstIndex { $0 > 0 })
        let top = try XCTUnwrap(rows.firstIndex { $0 > 0 })
        return CGRect(
            x: Double(left) + 1 - columns[left] / height,
            y: Double(top) + 1 - rows[top] / width,
            width: width,
            height: height
        )
    }

    func wrapper(_ scene: ShellLayerScene) throws -> CALayer {
        try ShellLayerScene.engineQueue.sync { try XCTUnwrap(scene.gestureLayers[0]?.layer) }
    }

    func springs(_ scene: ShellLayerScene) throws -> [CASpringAnimation] {
        let layer = try wrapper(scene)
        return try ShellLayerScene.engineQueue.sync {
            try Self.keys.map { try XCTUnwrap(layer.animation(forKey: $0) as? CASpringAnimation) }
        }
    }

    private func assertEqual(
        _ actual: CGRect,
        _ expected: CGRect,
        accuracy: CGFloat,
        _ message: String = "",
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, message, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, message, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, message, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, message, line: line)
    }

    func testMotionAddsOneNativeSpringPerChannelWithTheMotionTiming() throws {
        let begin = CACurrentMediaTime()
        let (scene, renderer) = try makeScene(at: begin)
        let motion = try motion(
            from: CGRect(x: 30, y: 20, width: 40, height: 40),
            velocity: .init(x: 400, y: -150, width: -60),
            to: CGRect(x: 60, y: 12, width: 32, height: 32),
            begin: begin
        )
        let channels = motion.wrapper(for: Self.home)
        manipulate(scene, .motion(channels))
        let layer = try wrapper(scene)
        let animations = try springs(scene)
        let model = ShellLayerScene.engineQueue.sync {
            (layer.transform, layer.convertTime(begin, from: nil), layer.position, layer.bounds)
        }
        for (animation, channel) in zip(animations, [channels.x, channels.y, channels.scale]) {
            XCTAssertEqual(animation.mass, 1, accuracy: 1e-9)
            XCTAssertEqual(animation.stiffness, 300, accuracy: 1.5)
            XCTAssertEqual(animation.damping, 20, accuracy: 0.2)
            XCTAssertEqual(try XCTUnwrap(animation.fromValue as? Double), channel.from)
            XCTAssertEqual(try XCTUnwrap(animation.toValue as? Double), channel.to)
            XCTAssertNotEqual(channel.velocity, 0)
            XCTAssertEqual(animation.initialVelocity, channel.velocity / (channel.to - channel.from), accuracy: 1e-9)
            XCTAssertEqual(animation.beginTime, model.1)
            XCTAssertEqual(animation.duration, motion.duration)
            XCTAssertNil(animation.delegate)
        }
        XCTAssertTrue(CATransform3DEqualToTransform(
            model.0,
            CATransform3DScale(
                CATransform3DMakeTranslation(channels.x.to, channels.y.to, 0),
                channels.scale.to,
                channels.scale.to,
                1
            )
        ))
        XCTAssertEqual(model.2, Self.home.origin)
        XCTAssertEqual(model.3, Self.home)
        withExtendedLifetime(renderer) {}
    }

    func testRenderedTranslationAndScaleMatchTheAnalyticMirror() throws {
        let targets = [CGRect(x: 120, y: 30, width: 40, height: 40), CGRect(x: 8, y: 8, width: 20, height: 20)]
        for target in targets {
            let begin = CACurrentMediaTime()
            let (scene, renderer) = try makeScene(at: begin)
            let motion = try motion(from: Self.home, to: target, begin: begin)
            manipulate(scene, .motion(motion.wrapper(for: Self.home)))
            for offset in [0, 0.05, 0.1, 0.222, 0.4] {
                let time = begin + offset
                assertEqual(try rendered(renderer, at: time), motion.rect(at: time), accuracy: 1, "\(target) \(offset)")
            }
        }
    }

    func testFastReleaseRetargetedHomeSettlesAtTheMotionDuration() throws {
        let begin = CACurrentMediaTime()
        let (scene, renderer) = try makeScene(at: begin)
        let settle = try motion(
            from: Self.home.offsetBy(dx: 99, dy: 0),
            velocity: .init(x: 800, y: 0, width: 0),
            to: Self.home,
            begin: begin
        )
        manipulate(scene, .motion(settle.wrapper(for: Self.home)), active: false)
        let end = begin + settle.duration
        let before = try rendered(renderer, at: end - 0.004)
        let after = try rendered(renderer, at: end + 0.004)
        XCTAssertLessThan(abs(after.minX - before.minX), 0.5)
        assertEqual(after, Self.home, accuracy: 0.5)
    }

    func testRetargetIsContinuousAtTheRetargetInstant() throws {
        let begin = CACurrentMediaTime()
        let (scene, renderer) = try makeScene(at: begin)
        let first = try motion(from: Self.home, to: CGRect(x: 120, y: 30, width: 40, height: 40), begin: begin)
        manipulate(scene, .motion(first.wrapper(for: Self.home)))
        let time = begin + 0.08
        let before = try rendered(renderer, at: time)
        let second = try XCTUnwrap(first.retargeted(at: time, to: CGRect(x: 20, y: 50, width: 40, height: 40)))
        manipulate(scene, .motion(second.wrapper(for: Self.home)))
        let after = try rendered(renderer, at: time)
        assertEqual(after, before, accuracy: 0.5)
        XCTAssertGreaterThan(abs(after.minX - second.target.minX), 10)
    }

    func testCommitRebaseInOneTransactionKeepsTheRenderedRect() throws {
        let begin = CACurrentMediaTime()
        let (scene, renderer) = try makeScene(at: begin)
        let release = CGRect(x: 100, y: 30, width: 40, height: 40)
        let drag = try motion(from: release, velocity: .init(x: -300, y: 120, width: 0), to: release, begin: begin)
        manipulate(scene, .motion(drag.wrapper(for: Self.home)), token: 3)
        let time = begin + 0.1
        let before = try rendered(renderer, at: time)
        let committed = Self.home.offsetBy(dx: 30, dy: 12)
        let settle = try XCTUnwrap(drag.retargeted(at: time, to: committed))
        submit([
            .frame(slot: 0, rect: committed, animation: nil),
            .manipulation(slot: 0, token: 3, presentation: .motion(settle.wrapper(for: committed)), active: false)
        ], to: scene)
        let after = try rendered(renderer, at: time)
        assertEqual(after, before, accuracy: 0.5)
        assertEqual(try rendered(renderer, at: time + settle.duration + 0.01), committed, accuracy: 0.5)
    }

    func testFrameDuringAnInFlightScaleMotionKeepsTheTopLeftPivot() throws {
        guard #available(macOS 27.2, *) else {
            throw XCTSkip(
                "CARenderer before macOS 27.2 draws a child resized during its parent's in-flight transform at its old size"
            )
        }
        let begin = CACurrentMediaTime()
        let (scene, renderer) = try makeScene(at: begin)
        let scale = try motion(from: Self.home, to: CGRect(x: 8, y: 8, width: 20, height: 20), begin: begin)
        manipulate(scene, .motion(scale.wrapper(for: Self.home)), active: false)
        submit([.frame(slot: 0, rect: CGRect(x: 8, y: 8, width: 44, height: 40), animation: nil)], to: scene)
        let layer = try wrapper(scene)
        let geometry = ShellLayerScene.engineQueue.sync { (layer.position, layer.bounds) }
        XCTAssertEqual(geometry.0, Self.home.origin)
        XCTAssertEqual(geometry.1, Self.home)
        let factor = scale.rect(at: begin + 0.1).width / Self.home.width
        assertEqual(
            try rendered(renderer, at: begin + 0.1),
            CGRect(x: 8, y: 8, width: 44 * factor, height: 40 * factor),
            accuracy: 1
        )
    }

    func testStillIdentityCancelRemovesTheMotionAndLeavesIdentity() throws {
        let begin = CACurrentMediaTime()
        let (scene, renderer) = try makeScene(at: begin)
        let motion = try motion(from: Self.home, to: CGRect(x: 120, y: 30, width: 40, height: 40), begin: begin)
        manipulate(scene, .motion(motion.wrapper(for: Self.home)), token: 5)
        XCTAssertEqual(try springs(scene).count, 3)
        manipulate(scene, .still(translation: .zero, scale: 1, clip: nil), token: 5, active: false)
        let layer = try wrapper(scene)
        let state = ShellLayerScene.engineQueue.sync {
            (Self.keys.map { layer.animation(forKey: $0) == nil }, layer.transform, layer.zPosition)
        }
        XCTAssertEqual(state.0, [true, true, true])
        XCTAssertTrue(CATransform3DIsIdentity(state.1))
        XCTAssertEqual(state.2, 0)
        assertEqual(try rendered(renderer, at: begin + 0.05), Self.home, accuracy: 0.5)
    }

    func testReducedMotionStillScaleRendersProportionallyAboutTheTopLeft() throws {
        let begin = CACurrentMediaTime()
        let (scene, renderer) = try makeScene(at: begin)
        manipulate(scene, .still(translation: .zero, scale: 0.5, clip: nil))
        assertEqual(try rendered(renderer, at: begin), CGRect(x: 8, y: 8, width: 20, height: 20), accuracy: 0.5)
    }

    func testDegenerateChannelStillRendersTheVelocityOvershoot() throws {
        let begin = CACurrentMediaTime()
        let (scene, renderer) = try makeScene(at: begin)
        let rest = CGRect(x: 60, y: 30, width: 40, height: 40)
        let motion = try motion(from: rest, velocity: .init(x: 300, y: 0, width: 0), to: rest, begin: begin)
        let channels = motion.wrapper(for: Self.home)
        XCTAssertEqual(channels.x.from, channels.x.to)
        manipulate(scene, .motion(channels))
        let x = try springs(scene)[0]
        XCTAssertEqual(try XCTUnwrap(x.fromValue as? Double), channels.x.to - 1e-3)
        XCTAssertEqual(x.initialVelocity, 300 / 1e-3, accuracy: 0.01)
        var peak = rest.minX
        for offset in [0, 0.02, 0.0675, 0.12, 0.25] {
            let time = begin + offset
            let edge = try rendered(renderer, at: time).minX
            XCTAssertEqual(edge, motion.rect(at: time).minX, accuracy: 1, "\(offset)")
            peak = max(peak, edge)
        }
        XCTAssertGreaterThan(peak, rest.minX + 5)
    }
}

extension ShellManipulationSceneTests {
    func testClipOutlineDrawsTheRecipeColorAndFalseDrawsNone() throws {
        let clip = CGSize(width: 30, height: 30)
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let black = CGColor(gray: 0, alpha: 1)
        for (outline, expected) in [
            (ShellManipulationClip.standardOutline, [178, 178, 178]),
            (red, [0, 0, 255]),
            (nil, [0, 0, 0])
        ]
            as [(CGColor?, [Int])]
        {
            let begin = CACurrentMediaTime()
            let (scene, renderer) = try makeScene(at: begin, fill: black)
            manipulate(
                scene,
                .still(translation: .zero, scale: 1, clip: ShellManipulationClip(size: clip, outline: outline))
            )
            let layer = try wrapper(scene)
            let state = ShellLayerScene.engineQueue.sync {
                (layer.borderWidth, layer.borderColor, layer.masksToBounds, layer.bounds.size)
            }
            XCTAssertEqual(state.0, outline == nil ? 0 : 1)
            XCTAssertTrue(ShellLayerScene.same(state.1, outline))
            XCTAssertTrue(state.2)
            XCTAssertEqual(state.3, clip)
            let bytes = try ShellLayerScene.engineQueue.sync { try renderer.render(paused: begin) }
            let border = (20 * Self.width + 37) * 4
            for (channel, value) in expected.enumerated() {
                XCTAssertEqual(Int(bytes[border + channel]), value, accuracy: 2, "\(String(describing: outline))")
            }
            XCTAssertEqual(Int(bytes[(20 * Self.width + 38) * 4 + 3]), 0)
        }
    }
}
