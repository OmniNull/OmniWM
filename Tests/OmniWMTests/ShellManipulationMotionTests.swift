// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class ShellManipulationMotionTests: XCTestCase {
    private let envelope = CGSize(width: 353 * 1.242, height: 460 * 1.242)

    private func desk() throws -> ShellSpringDynamics.Parameters {
        try XCTUnwrap(ShellSpringDynamics.Parameters(
            ShellAnimation(motion: .spring(response: 0.363, bounce: 0.42), speed: 1)
        ))
    }

    private func samples(_ motion: ShellManipulationMotion) -> [CFTimeInterval] {
        (0 ... Int((motion.duration / 0.002).rounded(.up))).map { motion.begin + Double($0) * 0.002 }
    }

    private func value(_ channel: ShellWrapperMotion.Channel, at time: CFTimeInterval) -> Double {
        channel.to + ShellSpringDynamics.position(
            at: time - channel.begin,
            displacement: channel.from - channel.to,
            initialVelocity: channel.velocity,
            spring: channel.spring
        )
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

    func testRetargetKeepsPresentedRectAndVelocityContinuous() throws {
        let motion = try XCTUnwrap(ShellManipulationMotion(
            from: CGRect(x: 100, y: 80, width: 400, height: 300),
            velocity: .init(x: 250, y: -120, width: 60),
            to: CGRect(x: 260, y: 40, width: 320, height: 240),
            begin: 10,
            spring: try desk()
        ))
        let time = 10.08
        let retargeted = try XCTUnwrap(motion.retargeted(at: time, to: CGRect(x: 40, y: 200, width: 360, height: 270)))
        XCTAssertEqual(retargeted.begin, time)
        XCTAssertNotEqual(retargeted.duration, motion.duration)
        assertEqual(retargeted.rect(at: time), motion.rect(at: time), accuracy: 1e-9)
        let before = motion.velocity(at: time)
        let after = retargeted.velocity(at: time)
        XCTAssertNotEqual(before, .zero)
        XCTAssertEqual(after.x, before.x, accuracy: 1e-9)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-9)
        XCTAssertEqual(after.width, before.width, accuracy: 1e-9)
    }

    func testWrapperDescribesTheSameAbsoluteRectForEveryLayout() throws {
        let motion = try XCTUnwrap(ShellManipulationMotion(
            from: CGRect(x: 100, y: 80, width: 400, height: 300),
            velocity: .init(x: 250, y: -120, width: 60),
            to: CGRect(x: 260, y: 40, width: 320, height: 240),
            begin: 10,
            spring: try desk()
        ))
        for layout in [CGRect(x: 120, y: 60, width: 400, height: 300), CGRect(
            x: 500,
            y: 200,
            width: 200,
            height: 150
        )] {
            let wrapper = motion.wrapper(for: layout)
            for channel in [wrapper.x, wrapper.y, wrapper.scale] {
                XCTAssertEqual(channel.begin, motion.begin)
                XCTAssertEqual(channel.duration, motion.duration)
                XCTAssertEqual(channel.spring.mass, motion.spring.mass)
                XCTAssertEqual(channel.spring.stiffness, motion.spring.stiffness)
                XCTAssertEqual(channel.spring.damping, motion.spring.damping)
            }
            for time in samples(motion) {
                let scale = value(wrapper.scale, at: time)
                let rendered = CGRect(
                    x: layout.minX + value(wrapper.x, at: time),
                    y: layout.minY + value(wrapper.y, at: time),
                    width: layout.width * scale,
                    height: layout.height * scale
                )
                assertEqual(rendered, motion.rect(at: time), accuracy: 1e-9, "\(layout) \(time)")
            }
        }
    }

    private func springs() throws -> [ShellSpringDynamics.Parameters] {
        try [
            desk(),
            XCTUnwrap(ShellSpringDynamics.Parameters(ShellAnimation(
                motion: .spring(response: 0.36, bounce: 0),
                speed: 1
            ))),
            ShellSpringDynamics.Parameters(mass: 1, stiffness: 100, damping: 20),
            ShellSpringDynamics.Parameters(mass: 1, stiffness: 100, damping: 50)
        ]
    }

    private func releasedHome(
        by distance: Double,
        spring: ShellSpringDynamics.Parameters
    ) throws -> ShellManipulationMotion {
        let release = CGRect(origin: CGPoint(x: 900, y: 120), size: envelope)
        let thrown = try XCTUnwrap(ShellManipulationMotion(
            from: release, velocity: .init(x: 800, y: 0, width: 0), to: release, begin: 4, spring: spring
        ))
        return try XCTUnwrap(thrown.retargeted(at: 4, to: release.offsetBy(dx: distance, dy: 0)))
    }

    private func calm(_ motion: ShellManipulationMotion, at time: CFTimeInterval) -> Bool {
        let rect = motion.rect(at: time)
        let velocity = motion.velocity(at: time)
        let target = motion.target
        let residuals = [
            rect.minX - target.minX, rect.minY - target.minY, rect.width - target.width, rect.height - target.height
        ]
        let speeds = [velocity.x, velocity.y, velocity.width, velocity.width * target.height / target.width]
        return residuals.allSatisfy { abs($0) < 0.25 } && speeds.allSatisfy { abs($0) < 1 }
    }

    func testVelocityAwareDurationSettlesAFastReleaseRetargetedHome() throws {
        for spring in try springs() {
            for distance in [-99.0, 99.0] {
                let settle = try releasedHome(by: distance, spring: spring)
                let home = settle.target
                let end = settle.begin + settle.duration
                let rect = settle.rect(at: end)
                let label = "\(spring.damping) \(distance)"
                XCTAssertEqual(settle.velocity(at: settle.begin).x, 800, accuracy: 1e-9, label)
                XCTAssertLessThan(abs(rect.minX - home.minX), 0.25, label)
                XCTAssertLessThan(abs(rect.minY - home.minY), 0.25, label)
                XCTAssertLessThan(abs(rect.width - home.width), 0.25, label)
                XCTAssertLessThan(abs(rect.height - home.height), 0.25, label)
                let velocity = settle.velocity(at: end)
                XCTAssertLessThan(abs(velocity.x), 1, label)
                XCTAssertLessThan(abs(velocity.y), 1, label)
                XCTAssertLessThan(abs(velocity.width) * max(1, home.height / home.width), 1, label)
                XCTAssertTrue(settle.settled(at: end), label)
                XCTAssertFalse(settle.settled(at: end - 0.001), label)
                XCTAssertNil(
                    stride(from: settle.begin, to: end - 0.02, by: 0.0005).first { calm(settle, at: $0) },
                    label
                )
            }
        }
    }

    func testTrajectoryBoundsContainEverySampledRect() throws {
        var motions = try springs().flatMap { spring in
            try [releasedHome(by: -99, spring: spring), releasedHome(by: 99, spring: spring)]
        }
        try motions.append(XCTUnwrap(ShellManipulationMotion(
            from: CGRect(x: 100, y: 80, width: 400, height: 300),
            velocity: .init(x: 250, y: -120, width: 60),
            to: CGRect(x: 260, y: 40, width: 320, height: 240),
            begin: 10,
            spring: desk()
        )))
        for motion in motions {
            let bounds = motion.trajectoryBounds.insetBy(dx: -1e-9, dy: -1e-9)
            for time in samples(motion) {
                XCTAssertTrue(bounds.contains(motion.rect(at: time)), "\(motion.rect(at: time)) \(bounds)")
            }
        }
        let settle = try releasedHome(by: -99, spring: desk())
        let presented = (0 ... 8000).map { settle.rect(at: settle.begin + Double($0) * 0.0001) }
        XCTAssertEqual(presented.map(\.minX).min() ?? 0, settle.trajectoryBounds.minX, accuracy: 0.001)
        XCTAssertEqual(presented.map(\.maxX).max() ?? 0, settle.trajectoryBounds.maxX, accuracy: 0.001)
        XCTAssertLessThan(settle.trajectoryBounds.minX, settle.target.minX - 1)
        XCTAssertGreaterThan(settle.trajectoryBounds.maxX, settle.start.maxX + 1)
    }

    func testScaleMotionKeepsTheContentOppositeCornerFixed() throws {
        let recipe = try XCTUnwrap(ShellManipulationRecipe(
            mode: .scale,
            target: 7,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            minimum: CGSize(width: envelope.width / 2, height: envelope.height / 2),
            maximum: envelope,
            resizeMask: ShellManipulationEdge.right.mask | ShellManipulationEdge.bottom.mask,
            inset: CGSize(width: 6.5 / 353, height: 0)
        ))
        let home = CGRect(origin: CGPoint(x: 1400, y: 60), size: envelope)
        let pivot = ShellManipulationGeometry.content(of: home, recipe: recipe).origin
        let shrunk = try XCTUnwrap(ShellManipulationGeometry.scaled(
            start: home, translation: CGPoint(x: -100, y: -100), recipe: recipe
        ))
        let smallest = try XCTUnwrap(ShellManipulationGeometry.scaled(
            start: home, translation: CGPoint(x: -200, y: -200), recipe: recipe
        ))
        let motion = try XCTUnwrap(ShellManipulationMotion(from: home, to: shrunk, begin: 2, spring: try desk()))
        let retargeted = try XCTUnwrap(motion.retargeted(at: 2.05, to: smallest))
        XCTAssertNotEqual(retargeted.velocity(at: 2.05).width, 0)
        for (segment, end) in [(motion, 2.05), (retargeted, retargeted.begin + retargeted.duration)] {
            for time in samples(segment) where time <= end {
                let corner = ShellManipulationGeometry.content(of: segment.rect(at: time), recipe: recipe).origin
                XCTAssertEqual(corner.x, pivot.x, accuracy: 1e-9, "\(time)")
                XCTAssertEqual(corner.y, pivot.y, accuracy: 1e-9, "\(time)")
            }
        }
    }
}
