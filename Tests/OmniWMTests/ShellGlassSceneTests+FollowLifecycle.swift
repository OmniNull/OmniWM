// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
extension ShellGlassSceneTests {
    private func followLifeOwn(
        _ from: CGRect, _ to: CGRect, _ spring: ShellSpringDynamics.Parameters, at elapsed: Double
    ) -> CGRect {
        func value(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
            end + ShellSpringDynamics.position(
                at: elapsed,
                displacement: start - end,
                initialVelocity: 0,
                spring: spring
            )
        }
        return CGRect(
            x: value(from.minX, to.minX), y: value(from.minY, to.minY),
            width: value(from.width, to.width), height: value(from.height, to.height)
        )
    }

    private func followLifeStill(_ own: CGRect, layout: CGRect, translation: CGPoint, scale: CGFloat) -> CGRect {
        CGRect(
            x: layout.minX + translation.x + scale * (own.minX - layout.minX),
            y: layout.minY + translation.y + scale * (own.minY - layout.minY),
            width: scale * own.width, height: scale * own.height
        )
    }

    private func followLifeStages(
        layout: CGRect, width: Int, height: Int, at begin: CFTimeInterval
    ) throws -> (wrapped: FollowStage, followed: FollowStage) {
        let wrapped = try followStage(width: width, height: height, at: begin)
        let followed = try followStage(width: width, height: height, at: begin)
        let canvas = CGRect(x: -layout.minX, y: -layout.minY, width: CGFloat(width), height: CGFloat(height))
        run(
            box(1, layout, fill: nil)
                + body(10, canvas, parent: 1, shapes: [FollowShape(slot: 11, rect: layout, follow: nil)]),
            on: wrapped
        )
        run(
            box(1, layout, fill: nil)
                + body(10, self.canvas(followed), after: 1, shapes: [FollowShape(slot: 11, rect: layout)]),
            on: followed
        )
        try requireNative(followed)
        return (wrapped, followed)
    }

    private func followLifeRewind(_ stages: [FollowStage], to time: CFTimeInterval) {
        ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for stage in stages {
                stage.scene.container.timeOffset = time
            }
            CATransaction.commit()
        }
    }

    func testDiagonalResizingOwnSpringUnderAStillScaledFollow() throws {
        let layout = CGRect(x: 30, y: 20, width: 60, height: 40)
        let moved = CGRect(x: 80, y: 44, width: 80, height: 40)
        let begin = CACurrentMediaTime()
        let (wrapped, followed) = try followLifeStages(layout: layout, width: 400, height: 240, at: begin)
        for stage in [wrapped, followed] {
            run([.frame(slot: 11, rect: moved, animation: Self.calm)], on: stage, animated: true)
        }
        let translation = CGPoint(x: -20, y: 50)
        let scale: CGFloat = 0.6
        let held = ShellManipulationPresentation.still(translation: translation, scale: scale, clip: nil)
        present(held, target: 1, layout: layout, on: wrapped)
        present(held, target: 1, layout: layout, followers: [FollowShape(slot: 11, rect: moved)], on: followed)
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { followed.scene.shapeTracks.follows[11]?.mode }, .composite)
        let spring = try Self.spring(Self.calm)
        for elapsed in [0, 0.03, 0.07, 0.12, 0.25, 0.45, 0.9] {
            let own = followLifeOwn(layout, moved, spring, at: elapsed)
            let expected = followLifeStill(own, layout: layout, translation: translation, scale: scale)
            try compare(followed, with: wrapped, expected: expected, at: begin + elapsed, "still at \(elapsed)")
        }
    }

    func testOwnSpringUnderAMovingScaleFollowThatStartsWithIt() throws {
        let layout = CGRect(x: 30, y: 20, width: 60, height: 40)
        let moved = CGRect(x: 90, y: 30, width: 60, height: 40)
        let begin = CACurrentMediaTime()
        let (wrapped, followed) = try followLifeStages(layout: layout, width: 400, height: 240, at: begin)
        for stage in [wrapped, followed] {
            run([.frame(slot: 11, rect: moved, animation: Self.calm)], on: stage, animated: true)
        }
        let start = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(followed.scene.shapeTracks.entries[11]?.begin)
        }
        let desk = try XCTUnwrap(ShellSpringDynamics.Parameters(
            ShellAnimation(motion: .spring(response: 0.363, bounce: 0.42), speed: 1)
        ))
        let motion = try XCTUnwrap(ShellManipulationMotion(
            from: layout, velocity: .init(x: 240, y: -90, width: -50),
            to: CGRect(x: 150, y: 90, width: 36, height: 24), begin: start, spring: desk
        ))
        let presentation = ShellManipulationPresentation.motion(motion.wrapper(for: layout))
        present(presentation, target: 1, layout: layout, on: wrapped)
        present(presentation, target: 1, layout: layout, followers: [FollowShape(slot: 11, rect: moved)], on: followed)
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { followed.scene.shapeTracks.follows[11]?.mode }, .composite)
        let spring = try Self.spring(Self.calm)
        for elapsed in [0, 0.04, 0.09, 0.16, 0.3, 0.5, 0.9] {
            let own = followLifeOwn(layout, moved, spring, at: elapsed)
            let expected = Self.composite(motion.rect(at: start + elapsed), layout: layout, offset: own)
            try compare(followed, with: wrapped, expected: expected, at: begin + elapsed, "motion at \(elapsed)")
        }
    }

    func testDragSampleRebuildKeepsTheOwnSpringClock() throws {
        let layout = CGRect(x: 30, y: 20, width: 60, height: 40)
        let moved = CGRect(x: 90, y: 20, width: 60, height: 40)
        let begin = CACurrentMediaTime()
        let (wrapped, followed) = try followLifeStages(layout: layout, width: 400, height: 240, at: begin)
        for stage in [wrapped, followed] {
            run([.frame(slot: 11, rect: moved, animation: Self.calm)], on: stage, animated: true)
        }
        let spring = try Self.spring(Self.calm)
        let follower = FollowShape(slot: 11, rect: moved)
        func play(_ translation: CGPoint, _ scale: CGFloat, at times: [Double]) throws {
            let held = ShellManipulationPresentation.still(translation: translation, scale: scale, clip: nil)
            present(held, target: 1, layout: layout, on: wrapped)
            present(held, target: 1, layout: layout, followers: [follower], on: followed)
            for elapsed in times {
                let own = followLifeOwn(layout, moved, spring, at: elapsed)
                let expected = followLifeStill(own, layout: layout, translation: translation, scale: scale)
                try compare(followed, with: wrapped, expected: expected, at: begin + elapsed, "\(scale) at \(elapsed)")
            }
        }
        try play(CGPoint(x: 100, y: 40), 0.5, at: [0, 0.04])
        followLifeRewind([wrapped, followed], to: begin)
        try play(CGPoint(x: 60, y: 90), 0.75, at: [0.08, 0.15, 0.3, 0.6, 1.0])
    }

    func testBodyRefreshKeepsAFixedRadiusFollowerAtItsFollowedTerminal() throws {
        let layout = CGRect(x: 30, y: 20, width: 60, height: 40)
        let begin = CACurrentMediaTime()
        let stage = try followStage(width: 256, height: 160, at: begin)
        let follower = FollowShape(slot: 11, rect: layout, radius: 8, follow: .fixed)
        let sibling = FollowShape(slot: 12, rect: CGRect(x: 180, y: 100, width: 30, height: 30), follow: nil)
        run(box(1, layout, fill: nil) + body(10, canvas(stage), after: 1, shapes: [follower, sibling]), on: stage)
        try requireNative(stage)
        present(
            .still(translation: CGPoint(x: 40, y: 30), scale: 0.5, clip: nil), target: 1, layout: layout,
            followers: [follower], on: stage
        )
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { stage.scene.shapeTracks.follows[11]?.mode }, .composite)
        let expected = CGRect(x: 70, y: 50, width: 30, height: 20)
        assertRect(try drawn(stage, at: begin, around: expected), expected, accuracy: 1, "followed")
        run([.frame(slot: 12, rect: CGRect(x: 180, y: 110, width: 30, height: 30), animation: nil)], on: stage)
        assertRect(try drawn(stage, at: begin, around: expected), expected, accuracy: 1, "after a sibling refresh")
    }

    func testGlassContentChangeKeepsTheFollowersOwnSpring() throws {
        let layout = CGRect(x: 30, y: 20, width: 60, height: 40)
        let moved = CGRect(x: 90, y: 20, width: 60, height: 40)
        let begin = CACurrentMediaTime()
        let stage = try followStage(width: 256, height: 128, at: begin)
        run(
            box(1, layout, fill: nil) + body(
                10,
                canvas(stage),
                after: 1,
                shapes: [FollowShape(slot: 11, rect: layout)]
            ),
            on: stage
        )
        try requireNative(stage)
        let content = ShellGlassContent(
            kind: .shape, recipe: "", shape: 0, paint: paint(radius: 4), params: .zero, follow: .scaled
        )
        run(
            [
                .frame(slot: 11, rect: moved, animation: Self.calm),
                .glass(slot: 11, content, animation: Self.calm)
            ],
            on: stage, animated: true
        )
        let spring = try Self.spring(Self.calm)
        for elapsed in [0.05, 0.12, 0.25] {
            let own = followLifeOwn(layout, moved, spring, at: elapsed)
            assertRect(try drawn(stage, at: begin + elapsed, around: own), own, accuracy: 1, "own spring at \(elapsed)")
        }
    }
}
