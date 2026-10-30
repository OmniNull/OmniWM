// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
extension ShellGlassSceneTests {
    func shadowReach(_ stage: FollowStage, at time: CFTimeInterval, column: Int, bottom: CGFloat) throws -> Int {
        let bytes = try pixels(stage, at: time)
        let width = stage.width
        let edge = try XCTUnwrap(Self.columnCrossings(bytes, width: width, column: column, rows: 0 ..< stage.height)
            .last)
        XCTAssertEqual(edge, Double(bottom), accuracy: 1)
        let start = Int(edge.rounded(.up)) + 1
        let end = try XCTUnwrap((start ..< stage.height).first { bytes[($0 * width + column) * 4 + 3] <= 2 })
        return end - Int(edge.rounded())
    }

    func closingStages(
        _ layout: CGRect,
        at begin: CFTimeInterval
    ) throws -> (wrapped: FollowStage, followed: FollowStage) {
        let wrapped = try followStage(width: 400, height: 160, at: begin)
        let followed = try followStage(width: 400, height: 160, at: begin)
        let inner = FollowShape(
            slot: 11, rect: CGRect(x: 10, y: 10, width: layout.width, height: layout.height), follow: nil, reveal: true
        )
        run(
            box(1, layout, fill: nil) + body(
                10,
                CGRect(x: -10, y: -10, width: 100, height: 80),
                parent: 1,
                shapes: [inner]
            ),
            on: wrapped
        )
        run(
            box(1, layout, fill: nil) + body(
                10, canvas(followed), after: 1, shapes: [FollowShape(slot: 11, rect: layout, reveal: true)]
            ),
            on: followed
        )
        try requireNative(followed)
        return (wrapped, followed)
    }

    func testClosingAScaledMovedFollowerRevealStaysOnTheWrappedContentEdges() throws {
        let layout = CGRect(x: 20, y: 20, width: 80, height: 60)
        let begin = CACurrentMediaTime()
        let (wrapped, followed) = try closingStages(layout, at: begin)
        let follower = FollowShape(slot: 11, rect: layout, reveal: true)
        let held = ShellManipulationPresentation.still(translation: CGPoint(x: 200, y: 10), scale: 0.5, clip: nil)
        present(held, target: 1, layout: layout, on: wrapped)
        present(held, target: 1, layout: layout, followers: [follower], on: followed)
        let closing = ShellReveal(
            begin: begin, commit: begin, progress: 1, target: 0,
            spring: ShellMorphRecipe.Spring(response: 0.482, bounce: 0.31).parameters
        )
        for stage in [wrapped, followed] {
            run([.reveal(slot: 11, token: 0, closing), .remove(slot: 11)], on: stage, animated: true)
        }
        let carrier = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(followed.scene.shapeTracks.follows.first { $0.value.mode == .composite })
        }
        XCTAssertNotEqual(carrier.key, 11)
        var compared = 0
        for elapsed in [0, 0.03, 0.06, 0.1, 0.14] {
            let progress = closing.state(at: begin + elapsed).progress
            guard progress >= 0.15 else { continue }
            let expected = CGRect(
                x: 260 - 40 * progress,
                y: 45 - 15 * progress,
                width: 40 * progress,
                height: 30 * progress
            )
            try compare(
                followed, with: wrapped, expected: expected, around: expected.offsetBy(
                    dx: expected.width / 2 - 3,
                    dy: 0
                ),
                at: begin + elapsed, "at \(elapsed)"
            )
            compared += 1
        }
        XCTAssertGreaterThanOrEqual(compared, 4)
    }

    func testFixedRadiusFollowerKeepsItsBodyRadiusWhileItsSizeScales() throws {
        let layout = CGRect(x: 20, y: 20, width: 120, height: 80)
        for scale in [0.5, 1.6] as [CGFloat] {
            let begin = CACurrentMediaTime()
            let presented = CGRect(
                origin: layout.origin,
                size: CGSize(width: layout.width * scale, height: layout.height * scale)
            )
            var masks: [String: [Bool]] = [:]
            for (name, radius) in [("fixed", ShellFollowRadius.fixed), ("scaled", .scaled)] {
                let stage = try followStage(width: 256, height: 192, at: begin)
                let follower = FollowShape(slot: 11, rect: layout, radius: 16, follow: radius)
                run(box(1, layout, fill: nil) + body(10, canvas(stage), after: 1, shapes: [follower]), on: stage)
                try requireNative(stage)
                present(
                    .still(translation: .zero, scale: scale, clip: nil), target: 1, layout: layout,
                    followers: [follower], on: stage
                )
                masks[name] = try Self.mask(pixels(stage, at: begin))
                if radius == .fixed {
                    assertRect(try drawn(stage, at: begin, around: presented), presented, accuracy: 1, "scale \(scale)")
                }
            }
            for (name, radius) in [("body", 16), ("content", 16 * scale)] {
                let stage = try followStage(width: 256, height: 192, at: begin)
                let shape = FollowShape(slot: 11, rect: presented, radius: radius, follow: nil)
                run(body(10, canvas(stage), shapes: [shape]), on: stage)
                masks[name] = try Self.mask(pixels(stage, at: begin))
            }
            let fixed = try XCTUnwrap(masks["fixed"]), scaled = try XCTUnwrap(masks["scaled"])
            XCTAssertEqual(try Self.strays(fixed, from: XCTUnwrap(masks["body"]), width: 256), 0, "scale \(scale)")
            XCTAssertGreaterThan(try Self.strays(fixed, from: XCTUnwrap(masks["content"]), width: 256), 40)
            XCTAssertEqual(try Self.strays(scaled, from: XCTUnwrap(masks["content"]), width: 256), 0, "scale \(scale)")
        }
    }

    func testFollowedBodyShadowKeepsItsRadiusAtHalfScaleAndAcrossTheCommit() throws {
        let layout = CGRect(x: 60, y: 40, width: 120, height: 80)
        let committed = CGRect(x: 60, y: 40, width: 60, height: 40)
        let shadow = CGColor(gray: 0, alpha: 0.3)
        let recipe = "glass:4:-1:0:0:7|optics:0:1:90"
        let half = ShellManipulationPresentation.still(translation: .zero, scale: 0.5, clip: nil)
        let begin = CACurrentMediaTime()
        let followed = try followStage(width: 320, height: 240, at: begin)
        let follower = FollowShape(slot: 11, rect: layout)
        run(
            box(1, layout, fill: nil) + body(
                10, canvas(followed), after: 1, recipe: recipe, shadow: shadow, shadowRadius: 20, shapes: [follower]
            ),
            on: followed
        )
        try requireNative(followed)
        present(half, target: 1, layout: layout, followers: [follower], on: followed)
        let held = try shadowReach(followed, at: begin, column: 90, bottom: committed.maxY)
        run([
            .frame(slot: 1, rect: committed, animation: nil),
            .frame(slot: 11, rect: committed, animation: nil),
            .manipulation(slot: 1, token: 1, presentation: .identity, active: false),
            .manipulation(slot: 11, token: 1, presentation: .identity, active: false)
        ], on: followed)
        let settled = try shadowReach(followed, at: begin, column: 90, bottom: committed.maxY)
        XCTAssertEqual(Double(held), Double(settled), accuracy: 1)
        XCTAssertGreaterThan(held, 20)
        let wrapped = try followStage(width: 320, height: 240, at: begin)
        let inner = FollowShape(
            slot: 11,
            rect: CGRect(x: 40, y: 40, width: layout.width, height: layout.height),
            follow: nil
        )
        run(
            box(1, layout, fill: nil) + body(
                10, CGRect(x: -40, y: -40, width: 200, height: 160), parent: 1, recipe: recipe, shadow: shadow,
                shadowRadius: 20, shapes: [inner]
            ),
            on: wrapped
        )
        present(half, target: 1, layout: layout, on: wrapped)
        XCTAssertLessThan(try shadowReach(wrapped, at: begin, column: 90, bottom: committed.maxY), held - 4)
    }

    func testOwnSpringRunningWhenAScaledFollowStartsStaysOnTheWrappedContent() throws {
        let layout = CGRect(x: 20, y: 20, width: 80, height: 60)
        let moved = layout.offsetBy(dx: 60, dy: 0)
        let begin = CACurrentMediaTime()
        let wrapped = try followStage(width: 400, height: 200, at: begin)
        let followed = try followStage(width: 400, height: 200, at: begin)
        run(
            box(1, layout, fill: nil) + body(
                10, CGRect(x: -20, y: -20, width: 400, height: 200), parent: 1,
                shapes: [FollowShape(slot: 11, rect: layout, follow: nil)]
            ),
            on: wrapped
        )
        run(
            box(1, layout, fill: nil) + body(
                10,
                canvas(followed),
                after: 1,
                shapes: [FollowShape(slot: 11, rect: layout)]
            ),
            on: followed
        )
        try requireNative(followed)
        for stage in [wrapped, followed] {
            run([.frame(slot: 11, rect: moved, animation: Self.calm)], on: stage, animated: true)
        }
        let held = ShellManipulationPresentation.still(translation: CGPoint(x: 100, y: 40), scale: 0.5, clip: nil)
        present(held, target: 1, layout: layout, on: wrapped)
        present(held, target: 1, layout: layout, followers: [FollowShape(slot: 11, rect: moved)], on: followed)
        let spring = try Self.spring(Self.calm)
        for elapsed in [0, 0.05, 0.1, 0.2, 0.6] {
            let own = moved.minX + ShellSpringDynamics.position(
                at: elapsed, displacement: layout.minX - moved.minX, initialVelocity: 0, spring: spring
            )
            let expected = CGRect(x: 120 + 0.5 * (own - layout.minX), y: 60, width: 40, height: 30)
            try compare(
                followed, with: wrapped, expected: expected, around: CGRect(x: 135, y: 60, width: 40, height: 30),
                at: begin + elapsed, "at \(elapsed)"
            )
        }
    }

    func testTransformFollowerScalesAboutItsTrackTerminalOrigin() throws {
        let layout = CGRect(x: 20, y: 20, width: 80, height: 60)
        let follower = FollowShape(
            slot: 11, rect: layout, morph: "morph:0:0:0:0:0:0:0,1,1,1,1,1;1,1,1,1,1,1|offsets:0,0,1;20,10,1"
        )
        let begin = CACurrentMediaTime()
        let stage = try followStage(width: 256, height: 128, at: begin)
        run(box(1, layout, fill: nil) + body(10, canvas(stage), after: 1, shapes: [follower]), on: stage)
        try requireNative(stage)
        let terminal = layout.offsetBy(dx: 20, dy: 10)
        assertRect(try drawn(stage, at: begin, around: terminal), terminal, accuracy: 1, "terminal")
        present(
            .still(translation: CGPoint(x: 40, y: 10), scale: 0.5, clip: nil), target: 1, layout: layout,
            followers: [follower], on: stage
        )
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { stage.scene.shapeTracks.follows[11]?.mode }, .transform)
        let expected = CGRect(x: 70, y: 35, width: 40, height: 30)
        assertRect(try drawn(stage, at: begin, around: expected), expected, accuracy: 1, "followed")
    }

    func testEllipseFollowerTakesTheSampledCompositeAtThePresentedRect() throws {
        let layout = CGRect(x: 20, y: 20, width: 120, height: 60)
        let presented = CGRect(x: 60, y: 30, width: 60, height: 30)
        let follower = FollowShape(slot: 11, rect: layout, kind: 1)
        let begin = CACurrentMediaTime()
        let stage = try followStage(width: 256, height: 128, at: begin)
        run(box(1, layout, fill: nil) + body(10, canvas(stage), after: 1, shapes: [follower]), on: stage)
        try requireNative(stage)
        present(
            .still(translation: CGPoint(x: 40, y: 10), scale: 0.5, clip: nil), target: 1, layout: layout,
            followers: [follower], on: stage
        )
        let mode = ShellLayerScene.engineQueue.sync { stage.scene.shapeTracks.follows[11]?.mode }
        XCTAssertEqual(mode, .composite)
        let reference = try followStage(width: 256, height: 128, at: begin)
        run(
            body(10, canvas(reference), shapes: [FollowShape(slot: 11, rect: presented, follow: nil, kind: 1)]),
            on: reference
        )
        let drawn = try Self.mask(pixels(stage, at: begin))
        XCTAssertEqual(try Self.strays(drawn, from: Self.mask(pixels(reference, at: begin)), width: 256), 0)
        XCTAssertGreaterThan(drawn.count(where: \.self), 1000)
    }
}
