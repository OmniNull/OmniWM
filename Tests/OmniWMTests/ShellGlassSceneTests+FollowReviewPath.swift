// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
extension ShellGlassSceneTests {
    private func followReviewPathCommands(_ stage: FollowStage, shape: FollowShape) throws -> [ShellLayerCommand] {
        let identity = "morph:0.5:0.5:0:0:0:0:0,1,1,1,1,1;1,1,1,1,1,1"
        var shapePaint = paint(radius: shape.radius)
        shapePaint.morph = try XCTUnwrap(ShellMorphRecipe(identity))
        var pathPaint = ShellLayerPaint(
            fill: ShellLayerScene.clear, border: Self.white, borderWidth: 1, radius: 0,
            opacity: 1, scale: 1, shadow: nil, shadowRadius: 0
        )
        pathPaint.morph = try XCTUnwrap(ShellMorphRecipe(identity + "|track:11"))
        let path = try XCTUnwrap(ShellPath.parse(
            "M 38 20 Q 30 20 30 28 L 30 52 Q 30 60 38 60 L 82 60 Q 90 60 90 52 L 90 28 Q 90 20 82 20 Z"
        ))
        return box(1, shape.rect, fill: nil) + body(10, canvas(stage), after: 1, shapes: []) + [
            .insert(
                slot: shape.slot, parent: 10, kind: .shape, after: -1,
                identity: ShellLayerIdentity(parent: .none, key: 11, kind: .shape)
            ),
            .glass(
                slot: shape.slot,
                ShellGlassContent(
                    kind: .shape, recipe: "", shape: 0, paint: shapePaint, params: .zero, follow: shape.follow
                ),
                animation: nil
            ),
            .frame(slot: shape.slot, rect: shape.rect, animation: nil),
            .insert(slot: 20, parent: -1, kind: .path, after: 10),
            .frame(slot: 20, rect: canvas(stage), animation: nil),
            .paint(slot: 20, pathPaint, animation: nil),
            .path(slot: 20, ShellLayerPath(path: path, viewBox: nil, evenOdd: false), animation: nil)
        ]
    }

    private func followReviewPathBounds(_ stage: FollowStage, at time: CFTimeInterval, outline: Bool) throws -> CGRect {
        let bytes = try ShellLayerScene.engineQueue.sync {
            let body = try XCTUnwrap(stage.scene.layers[10])
            let path = try XCTUnwrap(stage.scene.layers[20])
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            body.isHidden = outline
            path.isHidden = !outline
            CATransaction.commit()
            defer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                body.isHidden = false
                path.isHidden = false
                CATransaction.commit()
            }
            return try stage.renderer.render(paused: time)
        }
        var left = stage.width, right = -1, top = stage.height, bottom = -1
        for y in 0 ..< stage.height {
            for x in 0 ..< stage.width where bytes[(y * stage.width + x) * 4 + 3] > 16 {
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        XCTAssertGreaterThanOrEqual(right, left, "missing \(outline ? "outline" : "fill") pixels at \(time)")
        guard right >= left else { throw NSError(domain: "FollowReviewPathPixels", code: 1) }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    private func assertFollowReviewPath(
        _ stage: FollowStage, expected: CGRect, at time: CFTimeInterval, _ message: String
    ) throws {
        let fill = try followReviewPathBounds(stage, at: time, outline: false)
        let path = try followReviewPathBounds(stage, at: time, outline: true)
        assertFollowReviewPathRect(fill, expected, "native fill: \(message)")
        assertFollowReviewPathRect(path, fill, "tracked pencil versus native fill: \(message)")
    }

    private func assertFollowReviewPathRect(
        _ actual: CGRect, _ expected: CGRect, _ message: String, line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, message, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, message, line: line)
        XCTAssertEqual(actual.maxX, expected.maxX, accuracy: 1, message, line: line)
        XCTAssertEqual(actual.maxY, expected.maxY, accuracy: 1, message, line: line)
    }

    func testFollowReviewTrackedPencilEdgesFollowAStillFixedRadiusHalfScaleInCARenderer() async throws {
        let layout = CGRect(x: 30, y: 20, width: 60, height: 40)
        let follower = FollowShape(slot: 11, rect: layout, radius: 8, follow: .fixed)
        let begin = CACurrentMediaTime()
        let stage = try followStage(width: 256, height: 128, at: begin)
        await apply(try followReviewPathCommands(stage, shape: follower), to: stage.scene)
        try requireNative(stage)
        try assertFollowReviewPath(stage, expected: layout, at: begin, "identity control")
        present(
            .still(translation: CGPoint(x: 40, y: 30), scale: 0.5, clip: nil),
            target: 1, layout: layout, followers: [follower], on: stage
        )
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { stage.scene.shapeTracks.follows[11]?.mode }, .composite)
        let expected = CGRect(x: 70, y: 50, width: 30, height: 20)
        for elapsed in [0, 0.05, 0.2, 0.6] {
            try assertFollowReviewPath(stage, expected: expected, at: begin + elapsed, "held at \(elapsed)")
        }
    }

    func testFollowReviewTrackedPencilEdgesKeepTheMovingFollowTailBeyondTheirOwnTrackInCARenderer() async throws {
        let layout = CGRect(x: 30, y: 20, width: 60, height: 40)
        let follower = FollowShape(slot: 11, rect: layout, radius: 8, follow: .fixed)
        let begin = CACurrentMediaTime()
        let stage = try followStage(width: 256, height: 128, at: begin)
        await apply(try followReviewPathCommands(stage, shape: follower), to: stage.scene)
        try requireNative(stage)
        let motion = try XCTUnwrap(ShellManipulationMotion(
            from: layout, to: CGRect(x: 150, y: 70, width: 30, height: 20),
            begin: begin, spring: Self.spring(Self.calm)
        ))
        present(
            .motion(motion.wrapper(for: layout)), target: 1, layout: layout, followers: [follower], on: stage
        )
        let entry = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(stage.scene.shapeTracks.entries[11])
        }
        XCTAssertEqual(entry.base.duration, 0)
        XCTAssertGreaterThan(motion.duration, entry.duration)
        XCTAssertGreaterThan(motion.duration, 0.2)
        for elapsed in [0, motion.duration * 0.15, motion.duration * 0.5, motion.duration + 0.05] {
            let expected = elapsed >= motion.duration ? motion.target : motion.rect(at: begin + elapsed)
            try assertFollowReviewPath(stage, expected: expected, at: begin + elapsed, "moving tail at \(elapsed)")
        }
    }

    func testFollowReviewTrackedPencilEdgesFollowTheHeldTransformRouteInCARenderer() async throws {
        let layout = CGRect(x: 30, y: 20, width: 60, height: 40)
        let follower = FollowShape(slot: 11, rect: layout, radius: 8, follow: .scaled)
        let begin = CACurrentMediaTime()
        let stage = try followStage(width: 256, height: 128, at: begin)
        await apply(try followReviewPathCommands(stage, shape: follower), to: stage.scene)
        try requireNative(stage)
        present(
            .still(translation: CGPoint(x: 40, y: 30), scale: 0.5, clip: nil),
            target: 1, layout: layout, followers: [follower], on: stage
        )
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { stage.scene.shapeTracks.follows[11]?.mode }, .transform)
        for elapsed in [0, 0.05, 0.2, 0.6] {
            try assertFollowReviewPath(
                stage, expected: CGRect(x: 70, y: 50, width: 30, height: 20),
                at: begin + elapsed, "held transform at \(elapsed)"
            )
        }
    }

    func testFollowReviewTrackedPencilEdgesFollowTheMovingTransformRouteInCARenderer() async throws {
        let layout = CGRect(x: 30, y: 20, width: 60, height: 40)
        let follower = FollowShape(slot: 11, rect: layout, radius: 8, follow: .scaled)
        let begin = CACurrentMediaTime()
        let stage = try followStage(width: 256, height: 128, at: begin)
        await apply(try followReviewPathCommands(stage, shape: follower), to: stage.scene)
        try requireNative(stage)
        let motion = try XCTUnwrap(ShellManipulationMotion(
            from: layout, to: CGRect(x: 150, y: 70, width: 30, height: 20),
            begin: begin, spring: Self.spring(Self.calm)
        ))
        present(
            .motion(motion.wrapper(for: layout)), target: 1, layout: layout, followers: [follower], on: stage
        )
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { stage.scene.shapeTracks.follows[11]?.mode }, .transform)
        for elapsed in [0, motion.duration * 0.15, motion.duration * 0.5, motion.duration + 0.05] {
            let expected = elapsed >= motion.duration ? motion.target : motion.rect(at: begin + elapsed)
            try assertFollowReviewPath(stage, expected: expected, at: begin + elapsed, "moving transform at \(elapsed)")
        }
    }
}
