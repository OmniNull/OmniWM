// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellSpringDynamicsTests: XCTestCase {
    func testInitialVelocitySurvivesARetargetWithDifferentDisplacementAndSpring() {
        let previous = ShellSpringDynamics.velocity(
            at: 0.17, displacement: -80, initialVelocity: 140, spring: .init(mass: 1, stiffness: 220, damping: 18)
        )
        XCTAssertNotEqual(previous, 0)
        let retargeted = ShellSpringDynamics.velocity(
            at: 0, displacement: 35, initialVelocity: previous, spring: .init(mass: 2, stiffness: 400, damping: 12)
        )
        XCTAssertEqual(retargeted, previous)
    }

    func testUndampedVelocityMatchesHarmonicMotion() {
        for time in [0.0, 0.1, 0.5, 1.0, 2.0] {
            let velocity = ShellSpringDynamics.velocity(
                at: time, displacement: -3, initialVelocity: 4, spring: .init(mass: 2, stiffness: 8, damping: 0)
            )
            XCTAssertEqual(velocity, 6 * sin(2 * time) + 4 * cos(2 * time), accuracy: 1e-12)
        }
    }

    func testCriticalAndOverdampedClosedForms() {
        for time in [0.0, 0.1, 0.5, 1.0, 2.0] {
            let critical = ShellSpringDynamics.velocity(
                at: time, displacement: -3, initialVelocity: 4, spring: .init(mass: 2, stiffness: 8, damping: 8)
            )
            XCTAssertEqual(critical, exp(-2 * time) * (4 + 4 * time), accuracy: 1e-12)
            let overdamped = ShellSpringDynamics.velocity(
                at: time, displacement: -3, initialVelocity: 4, spring: .init(mass: 2, stiffness: 12, damping: 10)
            )
            XCTAssertEqual(overdamped, 10 * exp(-2 * time) - 6 * exp(-3 * time), accuracy: 1e-12)
        }
    }

    func testVelocityMatchesIndependentIntegrationInEveryDampingRegime() {
        for damping in [2.0, 8.0, 20.0] {
            let expected = integrate(
                duration: 0.75, displacement: 3, velocity: -7, mass: 2, stiffness: 8, damping: damping
            )
            let actual = ShellSpringDynamics.velocity(
                at: 0.75, displacement: 3, initialVelocity: -7, spring: .init(mass: 2, stiffness: 8, damping: damping)
            )
            XCTAssertEqual(actual, expected, accuracy: 1e-8)
        }
    }

    func testNearCriticalSolutionsConvergeWithoutCancellation() {
        let critical = ShellSpringDynamics.velocity(
            at: 0.1, displacement: -1, initialVelocity: 3, spring: .init(mass: 1, stiffness: 100, damping: 20)
        )
        for damping in [20 - 1e-9, 20 + 1e-9] {
            let nearby = ShellSpringDynamics.velocity(
                at: 0.1, displacement: -1, initialVelocity: 3, spring: .init(mass: 1, stiffness: 100, damping: damping)
            )
            XCTAssertEqual(nearby, critical, accuracy: 1e-9)
        }
    }

    func testStrongOverdampingDoesNotOverflowAtLongElapsedTimes() {
        let velocity = ShellSpringDynamics.velocity(
            at: 50, displacement: -1, initialVelocity: 0, spring: .init(mass: 1, stiffness: 100, damping: 2000)
        )
        XCTAssertGreaterThan(velocity, 0.004)
        XCTAssertLessThan(velocity, 0.0042)
        XCTAssertEqual(ShellSpringDynamics.velocity(
            at: 1e9, displacement: -1, initialVelocity: 0, spring: .init(mass: 1, stiffness: 100, damping: 2000)
        ), 0)
    }

    func testPhysicalDirectionAndMassScalingStayWithTheCaller() {
        let forward = ShellSpringDynamics.velocity(
            at: 0.25, displacement: -40, initialVelocity: 20, spring: .init(mass: 1, stiffness: 100, damping: 10)
        )
        let reversed = ShellSpringDynamics.velocity(
            at: 0.25, displacement: 40, initialVelocity: -20, spring: .init(mass: 1, stiffness: 100, damping: 10)
        )
        let scaled = ShellSpringDynamics.velocity(
            at: 0.25, displacement: -40, initialVelocity: 20, spring: .init(mass: 3, stiffness: 300, damping: 30)
        )
        XCTAssertEqual(reversed, -forward, accuracy: 1e-12)
        XCTAssertEqual(scaled, forward, accuracy: 1e-12)
    }

    func testInvalidInputsReturnNoVelocity() {
        let samples: [(Double, Double, Double, Double, Double, Double)] = [
            (-1, 1, 1, 1, 100, 10), (.nan, 1, 1, 1, 100, 10), (.infinity, 1, 1, 1, 100, 10),
            (1, .nan, 1, 1, 100, 10), (1, 1, .infinity, 1, 100, 10),
            (1, 1, 1, 0, 100, 10), (1, 1, 1, .infinity, 100, 10),
            (1, 1, 1, 1, 0, 10), (1, 1, 1, 1, .nan, 10),
            (1, 1, 1, 1, 100, -1), (1, 1, 1, 1, 100, .infinity)
        ]
        for (elapsed, displacement, velocity, mass, stiffness, damping) in samples {
            XCTAssertEqual(ShellSpringDynamics.velocity(
                at: elapsed, displacement: displacement, initialVelocity: velocity,
                spring: .init(mass: mass, stiffness: stiffness, damping: damping)
            ), 0)
        }
    }

    private func integrate(
        duration: Double,
        displacement: Double,
        velocity: Double,
        mass: Double,
        stiffness: Double,
        damping: Double
    ) -> Double {
        var position = displacement
        var speed = velocity
        let steps = 7500
        let step = duration / Double(steps)
        let acceleration = { (position: Double, speed: Double) in
            -(stiffness * position + damping * speed) / mass
        }
        for _ in 0 ..< steps {
            let firstPosition = speed
            let firstSpeed = acceleration(position, speed)
            let secondPosition = speed + firstSpeed * step / 2
            let secondSpeed = acceleration(position + firstPosition * step / 2, secondPosition)
            let thirdPosition = speed + secondSpeed * step / 2
            let thirdSpeed = acceleration(position + secondPosition * step / 2, thirdPosition)
            let fourthPosition = speed + thirdSpeed * step
            let fourthSpeed = acceleration(position + thirdPosition * step, fourthPosition)
            position += step * (firstPosition + 2 * secondPosition + 2 * thirdPosition + fourthPosition) / 6
            speed += step * (firstSpeed + 2 * secondSpeed + 2 * thirdSpeed + fourthSpeed) / 6
        }
        return speed
    }
}
