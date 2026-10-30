// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellSpringDynamicsTests: XCTestCase {
    func testUndampedVelocityMatchesHarmonicMotion() {
        for time in [0.0, 0.1, 0.5, 1.0, 2.0] {
            let velocity = ShellSpringDynamics.velocity(
                at: time, displacement: -3, initialVelocity: 4, spring: .init(mass: 2, stiffness: 8, damping: 0)
            )
            XCTAssertEqual(velocity, 6 * sin(2 * time) + 4 * cos(2 * time), accuracy: 1e-12)
        }
    }

    func testCriticalAndOverdampedClosedForms() {
        XCTAssertEqual(
            ShellSpringDynamics.velocity(
                at: 0, displacement: -3, initialVelocity: 4, spring: .init(mass: 2, stiffness: 8, damping: 8)
            ),
            4
        )
        let previous = ShellSpringDynamics.velocity(
            at: 0.17, displacement: -80, initialVelocity: 140, spring: .init(mass: 1, stiffness: 220, damping: 18)
        )
        XCTAssertNotEqual(previous, 0)
        let retargeted = ShellSpringDynamics.velocity(
            at: 0, displacement: 35, initialVelocity: previous, spring: .init(mass: 2, stiffness: 400, damping: 12)
        )
        XCTAssertEqual(retargeted, previous)

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

    func testPositionClosedFormsCoverEveryDampingRegime() {
        for time in [0.0, 0.1, 0.5, 1.0, 2.0] {
            let undamped = ShellSpringDynamics.position(
                at: time, displacement: -3, initialVelocity: 4, spring: .init(mass: 2, stiffness: 8, damping: 0)
            )
            XCTAssertEqual(undamped, -3 * cos(2 * time) + 2 * sin(2 * time), accuracy: 1e-12)
            let critical = ShellSpringDynamics.position(
                at: time, displacement: -3, initialVelocity: 4, spring: .init(mass: 2, stiffness: 8, damping: 8)
            )
            XCTAssertEqual(critical, exp(-2 * time) * (-3 - 2 * time), accuracy: 1e-12)
            let overdamped = ShellSpringDynamics.position(
                at: time, displacement: -3, initialVelocity: 4, spring: .init(mass: 2, stiffness: 12, damping: 10)
            )
            XCTAssertEqual(overdamped, -5 * exp(-2 * time) + 2 * exp(-3 * time), accuracy: 1e-12)
        }
    }

    func testPositionMatchesPleamarSemiImplicitEulerForDeskDripAndFollowSprings() {
        let step = 0.0005
        for (stiffness, damping) in [(300.0, 20.0), (170.0, 18.0), (304.6, 34.9)] {
            let spring = ShellSpringDynamics.Parameters(mass: 1, stiffness: stiffness, damping: damping)
            var value = 0.0
            var speed = 0.0
            var worst = 0.0
            for index in 1 ... 3000 {
                speed += (-stiffness * (value - 1) - damping * speed) * step
                value += speed * step
                let exact = 1 + ShellSpringDynamics.position(
                    at: Double(index) * step, displacement: -1, initialVelocity: 0, spring: spring
                )
                worst = max(worst, abs(exact - value))
            }
            XCTAssertLessThan(worst, 0.005, "\(stiffness):\(damping)")
        }
    }

    func testDripStepPeaksAtVitreusOvershoot() {
        let spring = ShellSpringDynamics.Parameters(mass: 1, stiffness: 170, damping: 18)
        var peak = (time: 0.0, value: 0.0)
        for index in 0 ... 6000 {
            let time = Double(index) * 0.0001
            let value = 1 + ShellSpringDynamics.position(at: time, displacement: -1, initialVelocity: 0, spring: spring)
            if value > peak.value { peak = (time, value) }
        }
        XCTAssertEqual(peak.value, 1.04993, accuracy: 0.0002)
        XCTAssertEqual(peak.time, 0.3330, accuracy: 0.0005)
    }

    func testPositionDerivativeMatchesVelocityInEveryDampingRegime() {
        let delta = 1e-6
        for (stiffness, damping) in [(300.0, 20.0), (304.6, 34.9), (100.0, 20.0), (100.0, 50.0)] {
            let spring = ShellSpringDynamics.Parameters(mass: 1, stiffness: stiffness, damping: damping)
            for time in [0.01, 0.05, 0.12, 0.3, 0.7] {
                let ahead = ShellSpringDynamics.position(
                    at: time + delta, displacement: -1, initialVelocity: 3, spring: spring
                )
                let behind = ShellSpringDynamics.position(
                    at: time - delta, displacement: -1, initialVelocity: 3, spring: spring
                )
                let velocity = ShellSpringDynamics.velocity(
                    at: time, displacement: -1, initialVelocity: 3, spring: spring
                )
                XCTAssertEqual((ahead - behind) / (2 * delta), velocity, accuracy: 1e-6, "\(stiffness):\(damping)")
            }
        }
    }

    func testNativeSpringMappingMatchesVitreusParameters() throws {
        func native(_ response: Double, _ bounce: Double) throws -> ShellSpringDynamics.Parameters {
            try XCTUnwrap(ShellSpringDynamics.Parameters(
                ShellAnimation(motion: .spring(response: response, bounce: bounce), speed: 1)
            ))
        }
        let desk = try native(0.363, 0.42)
        XCTAssertEqual(desk.mass, 1, accuracy: 1e-12)
        XCTAssertEqual(desk.stiffness, 300, accuracy: 1.5)
        XCTAssertEqual(desk.damping, 20, accuracy: 0.2)
        let drip = try native(0.482, 0.31)
        XCTAssertEqual(drip.mass, 1, accuracy: 1e-12)
        XCTAssertEqual(drip.stiffness, 170, accuracy: 1.5)
        XCTAssertEqual(drip.damping, 18, accuracy: 0.2)
        let follow = try native(0.360, 0)
        XCTAssertEqual(follow.mass, 1, accuracy: 1e-12)
        XCTAssertEqual(follow.stiffness, 305, accuracy: 3)
        XCTAssertEqual(follow.damping, 34.9, accuracy: 0.4)
        XCTAssertNil(ShellSpringDynamics.Parameters(ShellAnimation(motion: .ease, speed: 1)))
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
