// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
extension ShellManipulationSceneTests {
    private final class Settlements {
        var calls: [[UInt64]] = []
    }

    private struct Snapshot {
        let token: UInt64
        let generation: UInt64
        let animations: [CAAnimation?]
        let zPosition: CGFloat
    }

    private func completion(_ scene: ShellLayerScene) throws -> ShellManipulationCompletion {
        try XCTUnwrap(springs(scene).first?.delegate as? ShellManipulationCompletion)
    }

    private func drain() async {
        ShellLayerScene.engineQueue.sync {}
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func observe(_ scene: ShellLayerScene) -> Settlements {
        let settlements = Settlements()
        let handler: @MainActor @Sendable (Int32, UInt64, UInt64) -> Void = { slot, token, generation in
            settlements.calls.append([UInt64(slot), token, generation])
        }
        ShellLayerScene.engineQueue.sync { scene.onManipulationSettled = handler }
        return settlements
    }

    func testRaiseNeverTouchesTheSettleAndLowersOnlyAfterItCompletes() async throws {
        let begin = CACurrentMediaTime()
        let (scene, renderer) = try makeScene(at: begin)
        let release = CGRect(x: 100, y: 30, width: 40, height: 40)
        manipulate(scene, .still(translation: CGPoint(x: 92, y: 22), scale: 1, clip: nil), token: 9)
        let settle = try motion(from: release, to: Self.home, begin: begin)
        manipulate(scene, .motion(settle.wrapper(for: Self.home)), token: 9, active: false)
        let layer = try wrapper(scene)
        let animations = try springs(scene)
        func snapshot() -> Snapshot {
            ShellLayerScene.engineQueue.sync {
                let state = scene.gestureLayers[0]
                return Snapshot(
                    token: state?.token ?? 0,
                    generation: state?.generation ?? 0,
                    animations: Self.keys.map { layer.animation(forKey: $0) },
                    zPosition: layer.zPosition
                )
            }
        }
        let settling = snapshot()
        XCTAssertEqual(settling.token, 9)
        XCTAssertEqual(settling.generation, 1)
        XCTAssertEqual(settling.zPosition, 1)
        for raised in [true, false] {
            submit([.raise(slot: 0, raised)], to: scene)
            let current = snapshot()
            XCTAssertEqual(current.token, settling.token)
            XCTAssertEqual(current.generation, settling.generation)
            XCTAssertTrue(zip(current.animations, animations).allSatisfy { $0 === $1 })
            XCTAssertEqual(current.zPosition, 1)
        }
        try completion(scene).animationDidStop(animations[0], finished: true)
        await drain()
        XCTAssertEqual(snapshot().zPosition, 1)
        submit([.raise(slot: 0, false)], to: scene)
        let settled = snapshot()
        XCTAssertEqual(settled.token, settling.token)
        XCTAssertEqual(settled.generation, settling.generation)
        XCTAssertEqual(settled.zPosition, 0)
        withExtendedLifetime(renderer) {}
    }

    func testRetargetedSettleReportsOnceAfterTheFinalSegment() async throws {
        let begin = CACurrentMediaTime()
        let (scene, renderer) = try makeScene(at: begin)
        let settlements = observe(scene)
        let release = CGRect(x: 100, y: 30, width: 40, height: 40)
        let drag = try motion(from: Self.home, to: release, begin: begin)
        manipulate(scene, .motion(drag.wrapper(for: Self.home)), token: 4)
        XCTAssertNil(try springs(scene).first?.delegate)
        let first = try motion(from: release, to: Self.home, begin: begin)
        manipulate(scene, .motion(first.wrapper(for: Self.home)), token: 4, active: false)
        let superseded = try completion(scene)
        let second = try XCTUnwrap(first.retargeted(at: begin, to: Self.home.offsetBy(dx: 20, dy: 0)))
        manipulate(scene, .motion(second.wrapper(for: Self.home)), token: 4, active: false)
        let final = try completion(scene)
        XCTAssertFalse(final === superseded)
        let animation = try springs(scene)[0]
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.gestureLayers[0]?.generation }, 3)
        superseded.animationDidStop(animation, finished: false)
        superseded.animationDidStop(animation, finished: true)
        await drain()
        XCTAssertEqual(settlements.calls, [])
        final.animationDidStop(animation, finished: true)
        final.animationDidStop(animation, finished: true)
        await drain()
        XCTAssertEqual(settlements.calls, [[0, 4, 3]])
        withExtendedLifetime(renderer) {}
    }

    func testUnfinishedCallbackNeverReachesMain() async throws {
        let begin = CACurrentMediaTime()
        let (scene, renderer) = try makeScene(at: begin)
        let settlements = observe(scene)
        let settle = try motion(from: CGRect(x: 100, y: 30, width: 40, height: 40), to: Self.home, begin: begin)
        manipulate(scene, .still(translation: CGPoint(x: 92, y: 22), scale: 1, clip: nil), token: 6)
        manipulate(scene, .motion(settle.wrapper(for: Self.home)), token: 6, active: false)
        let animation = try springs(scene)[0]
        try completion(scene).animationDidStop(animation, finished: false)
        await drain()
        XCTAssertEqual(settlements.calls, [])
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.gestureLayers[0]?.moving }, true)
        withExtendedLifetime(renderer) {}
    }

    func testCompletionFromARecreatedWrapperNeverReportsForItsReplacement() async throws {
        let begin = CACurrentMediaTime()
        let (scene, renderer) = try makeScene(at: begin)
        let settlements = observe(scene)
        let settle = try motion(from: CGRect(x: 100, y: 30, width: 40, height: 40), to: Self.home, begin: begin)
        manipulate(scene, .motion(settle.wrapper(for: Self.home)), token: 3, active: false)
        let removed = try completion(scene)
        let animation = try springs(scene)[0]
        submit([
            .remove(slot: 0),
            .insert(slot: 0, parent: -1, kind: .box, after: -1),
            .frame(slot: 0, rect: Self.home, animation: nil)
        ], to: scene)
        manipulate(scene, .motion(settle.wrapper(for: Self.home)), token: 5, active: false)
        let replacement = try completion(scene)
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.gestureLayers[0]?.generation }, 1)
        removed.animationDidStop(animation, finished: true)
        await drain()
        XCTAssertEqual(settlements.calls, [])
        replacement.animationDidStop(animation, finished: true)
        await drain()
        XCTAssertEqual(settlements.calls, [[0, 5, 1]])
        withExtendedLifetime(renderer) {}
    }

    func testSupersededSettleNeverReportsAfterACancelOrARegrab() async throws {
        let begin = CACurrentMediaTime()
        let (scene, renderer) = try makeScene(at: begin)
        let settlements = observe(scene)
        let settle = try motion(from: CGRect(x: 100, y: 30, width: 40, height: 40), to: Self.home, begin: begin)
        manipulate(scene, .still(translation: CGPoint(x: 92, y: 22), scale: 1, clip: nil), token: 2)
        manipulate(scene, .motion(settle.wrapper(for: Self.home)), token: 2, active: false)
        let cancelled = try completion(scene)
        let animation = try springs(scene)[0]
        manipulate(scene, .still(translation: .zero, scale: 1, clip: nil), token: 2, active: false)
        cancelled.animationDidStop(animation, finished: true)
        await drain()
        XCTAssertEqual(settlements.calls, [])
        manipulate(scene, .still(translation: CGPoint(x: 92, y: 22), scale: 1, clip: nil), token: 8)
        manipulate(scene, .motion(settle.wrapper(for: Self.home)), token: 8, active: false)
        let superseded = try completion(scene)
        manipulate(scene, .still(translation: CGPoint(x: 40, y: 0), scale: 1, clip: nil), token: 11)
        manipulate(scene, .motion(settle.wrapper(for: Self.home)), token: 11, active: false)
        superseded.animationDidStop(animation, finished: true)
        cancelled.animationDidStop(animation, finished: true)
        await drain()
        XCTAssertEqual(settlements.calls, [])
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.gestureLayers[0]?.moving }, true)
        withExtendedLifetime(renderer) {}
    }
}
