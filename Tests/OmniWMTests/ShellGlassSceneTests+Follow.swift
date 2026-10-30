// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
extension ShellGlassSceneTests {
    struct FollowStage {
        let scene: ShellLayerScene
        let renderer: ShellOffscreenRenderer
        let width: Int
        let height: Int
    }

    struct FollowShape {
        let slot: Int32
        let rect: CGRect
        var radius: CGFloat = 0
        var follow: ShellFollowRadius? = .scaled
        var reveal = false
        var kind: UInt8 = 0
        var morph: String?
    }

    nonisolated static let flatFollow = "glass:4:-1:0:0:1|optics:0:1:90"
    nonisolated static let white = CGColor(gray: 1, alpha: 1)

    private var deskSpring: ShellSpringDynamics.Parameters {
        get throws {
            try XCTUnwrap(ShellSpringDynamics.Parameters(
                ShellAnimation(motion: .spring(response: 0.363, bounce: 0.42), speed: 1)
            ))
        }
    }

    func followStage(width: Int, height: Int, at begin: CFTimeInterval) throws -> FollowStage {
        let scene = motionScene(width: CGFloat(width), height: CGFloat(height))
        let renderer = try ShellLayerScene.engineQueue.sync {
            let renderer = try ShellOffscreenRenderer(root: scene.container, width: width, height: height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scene.container.speed = 0
            scene.container.timeOffset = begin
            CATransaction.commit()
            return renderer
        }
        return FollowStage(scene: scene, renderer: renderer, width: width, height: height)
    }

    func run(_ commands: [ShellLayerCommand], on stage: FollowStage, animated: Bool = false) {
        stage.scene.submit(commands, animated: animated)
        ShellLayerScene.engineQueue.sync {}
    }

    func box(
        _ slot: Int32,
        _ rect: CGRect,
        fill: CGColor?,
        parent: Int32 = -1,
        after: Int32 = -1
    ) -> [ShellLayerCommand] {
        [
            .insert(slot: slot, parent: parent, kind: .box, after: after),
            .frame(slot: slot, rect: rect, animation: nil),
            .paint(
                slot: slot,
                ShellLayerPaint(
                    fill: fill, border: nil, borderWidth: 0, radius: 0, opacity: 1, scale: 1, shadow: nil,
                    shadowRadius: 0
                ),
                animation: nil
            )
        ]
    }

    func body(
        _ slot: Int32,
        _ rect: CGRect,
        parent: Int32 = -1,
        after: Int32 = -1,
        recipe: String = ShellGlassSceneTests.flatFollow,
        shadow: CGColor = ShellLayerScene.clear,
        shadowRadius: CGFloat = 6,
        shapes: [FollowShape]
    ) -> [ShellLayerCommand] {
        let look = ShellLayerPaint(
            fill: Self.white, border: nil, borderWidth: 0, radius: 0, opacity: 1, scale: 1, shadow: shadow,
            shadowRadius: shadowRadius, blurRadius: 6, saturation: 1
        )
        var commands: [ShellLayerCommand] = [
            .insert(slot: slot, parent: parent, kind: .glass, after: after),
            .glass(
                slot: slot,
                ShellGlassContent(kind: .glass, recipe: recipe, shape: 0, paint: look, params: .zero),
                animation: nil
            ),
            .frame(slot: slot, rect: rect, animation: nil)
        ]
        var previous: Int32 = -1
        for shape in shapes {
            var look = paint(radius: shape.radius)
            if shape.reveal {
                look.reveal = ShellRevealRecipe("reveal:0.482:0.31")
                look.morph = ShellMorphRecipe("morph:1:0.5:0:0:0:0:0,0,1,1,1,1;1,1,1,1,1,1")
            }
            if let morph = shape.morph { look.morph = ShellMorphRecipe(morph) }
            commands += [
                .insert(slot: shape.slot, parent: slot, kind: .shape, after: previous),
                .glass(
                    slot: shape.slot,
                    ShellGlassContent(
                        kind: .shape, recipe: "", shape: shape.kind, paint: look, params: .zero, follow: shape.follow
                    ),
                    animation: nil
                ),
                .frame(slot: shape.slot, rect: shape.rect, animation: nil)
            ]
            previous = shape.slot
        }
        return commands
    }

    func present(
        _ presentation: ShellManipulationPresentation,
        target: Int32,
        layout: CGRect,
        followers: [FollowShape] = [],
        on stage: FollowStage
    ) {
        var commands: [ShellLayerCommand] = [
            .manipulation(slot: target, token: 1, presentation: presentation, active: true)
        ]
        for shape in followers {
            let offset = CGPoint(x: layout.minX - shape.rect.minX, y: layout.minY - shape.rect.minY)
            commands.append(.manipulation(
                slot: shape.slot, token: 1, presentation: presentation.following(offset), active: true
            ))
        }
        run(commands, on: stage)
    }

    nonisolated static func columnCrossings(
        _ bytes: [UInt8], width: Int, column: Int, rows: Range<Int>
    ) -> [Double] {
        let alpha = { (y: Int) in Double(bytes[(y * width + column) * 4 + 3]) / 255 }
        return rows.dropLast().compactMap { y in
            let inside = alpha(y)
            let next = alpha(y + 1)
            guard (inside >= 0.5) != (next >= 0.5) else { return nil }
            return Double(y) + 0.5 + (inside - 0.5) / (inside - next)
        }
    }

    func pixels(_ stage: FollowStage, at time: CFTimeInterval) throws -> [UInt8] {
        try ShellLayerScene.engineQueue.sync { try stage.renderer.render(paused: time) }
    }

    func drawn(
        _ stage: FollowStage, at time: CFTimeInterval, around expected: CGRect, rows: Range<Int>? = nil
    ) throws -> CGRect {
        let bytes = try pixels(stage, at: time)
        let xs = Self.crossings(bytes, width: stage.width, row: Int(expected.midY))
        let ys = Self.columnCrossings(
            bytes, width: stage.width, column: Int(expected.midX), rows: rows ?? 0 ..< stage.height
        )
        let left = try XCTUnwrap(xs.first, "no left edge at \(time)")
        let right = try XCTUnwrap(xs.last, "no right edge at \(time)")
        let top = try XCTUnwrap(ys.first, "no top edge at \(time)")
        let bottom = try XCTUnwrap(ys.last, "no bottom edge at \(time)")
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    func assertRect(
        _ actual: CGRect, _ expected: CGRect, accuracy: CGFloat, _ message: String = "", line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, message, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, message, line: line)
        XCTAssertEqual(actual.maxX, expected.maxX, accuracy: accuracy, message, line: line)
        XCTAssertEqual(actual.maxY, expected.maxY, accuracy: accuracy, message, line: line)
    }

    func requireNative(_ stage: FollowStage, _ slot: Int32 = 10) throws {
        _ = try ShellLayerScene.engineQueue.sync { try Self.native(stage.scene.glassBodies[slot]) }
    }

    func canvas(_ stage: FollowStage) -> CGRect {
        CGRect(x: 0, y: 0, width: stage.width, height: stage.height)
    }

    func compare(
        _ followed: FollowStage,
        with reference: FollowStage,
        expected: CGRect,
        around: CGRect? = nil,
        at time: CFTimeInterval,
        _ message: String
    ) throws {
        let wrapped = try drawn(reference, at: time, around: around ?? expected)
        let shape = try drawn(followed, at: time, around: around ?? expected)
        assertRect(shape, wrapped, accuracy: 1, message)
        assertRect(shape, expected, accuracy: 1, message)
    }

    func testFollowedShapeEdgesEqualTheWrapperPresentedContentForTranslationAndScale() throws {
        let layout = CGRect(x: 16, y: 16, width: 48, height: 48)
        let follower = FollowShape(slot: 11, rect: layout)
        for destination in [CGRect(x: 150, y: 48, width: 48, height: 48), CGRect(x: 16, y: 16, width: 24, height: 24)] {
            let begin = CACurrentMediaTime()
            let content = try followStage(width: 256, height: 128, at: begin)
            let followed = try followStage(width: 256, height: 128, at: begin)
            run(box(1, layout, fill: Self.white), on: content)
            run(box(1, layout, fill: nil) + body(10, canvas(followed), after: 1, shapes: [follower]), on: followed)
            try requireNative(followed)
            let motion = try XCTUnwrap(ShellManipulationMotion(
                from: layout, to: destination, begin: begin, spring: deskSpring
            ))
            let presentation = ShellManipulationPresentation.motion(motion.wrapper(for: layout))
            present(presentation, target: 1, layout: layout, on: content)
            present(presentation, target: 1, layout: layout, followers: [follower], on: followed)
            for offset in [0, 0.05, 0.1, 0.22, 0.4] {
                try compare(
                    followed, with: content, expected: motion.rect(at: begin + offset), at: begin + offset,
                    "\(destination) at \(offset)"
                )
            }
        }
    }

    nonisolated static func composite(_ shown: CGRect, layout: CGRect, offset: CGRect) -> CGRect {
        let scale = shown.width / layout.width
        return CGRect(
            x: shown.minX + scale * (offset.minX - layout.minX), y: shown.minY + scale * (offset.minY - layout.minY),
            width: offset.width * scale, height: offset.height * scale
        )
    }

    func testOffsetFollowerStaysOnTheWrapperCompositeThroughAVelocityRetarget() throws {
        let layout = CGRect(x: 20, y: 20, width: 40, height: 40)
        let offset = CGRect(x: 76, y: 32, width: 20, height: 20)
        let follower = FollowShape(slot: 11, rect: offset)
        let begin = CACurrentMediaTime()
        let reference = try followStage(width: 256, height: 160, at: begin)
        let followed = try followStage(width: 256, height: 160, at: begin)
        let child = offset.offsetBy(dx: -layout.minX, dy: -layout.minY)
        run(box(1, layout, fill: nil) + box(2, child, fill: Self.white, parent: 1), on: reference)
        run(box(1, layout, fill: nil) + body(10, canvas(followed), after: 1, shapes: [follower]), on: followed)
        try requireNative(followed)
        func composite(_ motion: ShellManipulationMotion, at time: CFTimeInterval) -> CGRect {
            Self.composite(motion.rect(at: time), layout: layout, offset: offset)
        }
        func play(_ motion: ShellManipulationMotion) {
            let presentation = ShellManipulationPresentation.motion(motion.wrapper(for: layout))
            present(presentation, target: 1, layout: layout, on: reference)
            present(presentation, target: 1, layout: layout, followers: [follower], on: followed)
        }
        func check(_ motion: ShellManipulationMotion, at offsets: [Double]) throws {
            for elapsed in offsets {
                let time = begin + elapsed
                try compare(followed, with: reference, expected: composite(motion, at: time), at: time, "\(elapsed)")
            }
        }
        let first = try XCTUnwrap(ShellManipulationMotion(
            from: layout, velocity: .init(x: 320, y: -140, width: -60),
            to: CGRect(x: 70, y: 50, width: 30, height: 30), begin: begin, spring: deskSpring
        ))
        play(first)
        try check(first, at: [0, 0.03, 0.06])
        let retarget = begin + 0.08
        let before = try drawn(followed, at: retarget, around: composite(first, at: retarget))
        _ = try pixels(reference, at: retarget)
        let second = try XCTUnwrap(first.retargeted(at: retarget, to: CGRect(x: 30, y: 80, width: 50, height: 50)))
        XCTAssertGreaterThan(abs(second.startVelocity.x) + abs(second.startVelocity.width), 10)
        play(second)
        assertRect(try drawn(followed, at: retarget, around: composite(second, at: retarget)), before, accuracy: 0.5)
        try check(second, at: [0.08, 0.12, 0.2, 0.35, 0.6])
    }

    func testCompositeFollowerKeepsItsMotionThroughAnUnrelatedUnanimatedSubmit() throws {
        let layout = CGRect(x: 20, y: 20, width: 60, height: 40)
        let follower = FollowShape(slot: 11, rect: layout, radius: 8, follow: .fixed, reveal: true)
        let begin = CACurrentMediaTime()
        let stage = try followStage(width: 256, height: 128, at: begin)
        run(box(1, layout, fill: nil) + body(10, canvas(stage), after: 1, shapes: [follower]), on: stage)
        try requireNative(stage)
        let motion = try XCTUnwrap(ShellManipulationMotion(
            from: layout, to: CGRect(x: 150, y: 40, width: 60, height: 40), begin: begin, spring: deskSpring
        ))
        present(.motion(motion.wrapper(for: layout)), target: 1, layout: layout, followers: [follower], on: stage)
        let tracked = ShellLayerScene.engineQueue.sync {
            (stage.scene.shapeTracks.follows[11]?.mode, stage.scene.shapeTracks.entries[11] != nil)
        }
        XCTAssertEqual(tracked.0, .composite)
        XCTAssertTrue(tracked.1)
        run([.raise(slot: 1, true)], on: stage)
        for elapsed in [0.05, 0.12, 0.2, 0.3] {
            let expected = motion.rect(at: begin + elapsed)
            assertRect(try drawn(stage, at: begin + elapsed, around: expected), expected, accuracy: 1, "at \(elapsed)")
        }
    }

    func testTwoTargetsDriveTheirOwnFollowersIndependently() throws {
        let first = CGRect(x: 16, y: 12, width: 40, height: 40)
        let second = CGRect(x: 16, y: 84, width: 40, height: 40)
        let followers = [FollowShape(slot: 11, rect: first), FollowShape(slot: 12, rect: second)]
        let begin = CACurrentMediaTime()
        let stage = try followStage(width: 256, height: 140, at: begin)
        run(
            box(1, first, fill: nil) + box(2, second, fill: nil, after: 1)
                + body(10, canvas(stage), after: 2, shapes: followers),
            on: stage
        )
        try requireNative(stage)
        let motions = try [
            XCTUnwrap(ShellManipulationMotion(
                from: first, to: CGRect(x: 160, y: 12, width: 40, height: 40), begin: begin, spring: deskSpring
            )),
            XCTUnwrap(ShellManipulationMotion(
                from: second, to: CGRect(x: 60, y: 94, width: 20, height: 20), begin: begin,
                spring: XCTUnwrap(ShellSpringDynamics.Parameters(Self.calm))
            ))
        ]
        for (index, layout) in [first, second].enumerated() {
            present(
                .motion(motions[index].wrapper(for: layout)), target: Int32(index + 1), layout: layout,
                followers: [followers[index]], on: stage
            )
        }
        for elapsed in [0, 0.05, 0.12, 0.3] {
            for (index, motion) in motions.enumerated() {
                let expected = motion.rect(at: begin + elapsed)
                assertRect(
                    try drawn(stage, at: begin + elapsed, around: expected, rows: index == 0 ? 0 ..< 70 : 70 ..< 140),
                    expected, accuracy: 1, "target \(index) at \(elapsed)"
                )
            }
        }
    }
}
