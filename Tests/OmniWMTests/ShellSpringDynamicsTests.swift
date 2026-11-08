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
            XCTAssertEqual(velocity, time == 0 ? 4 : exp(-0.0 * time) * (6 * sin(2 * time) + 4 * cos(2 * time)))
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
            XCTAssertEqual(critical, time == 0 ? 4 : exp(-2 * time) * (4 + 4 * time))
            let overdamped = ShellSpringDynamics.velocity(
                at: time, displacement: -3, initialVelocity: 4, spring: .init(mass: 2, stiffness: 18, damping: 20)
            )
            XCTAssertEqual(overdamped, time == 0 ? 4 : exp(-time) * (4 + 9 * (expm1(-8 * time) / 8)))
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
            XCTAssertEqual(actual, expected.velocity, accuracy: expected.velocityBound)
        }
    }

    func testNearCriticalSolutionsConvergeWithoutCancellation() {
        let critical = ShellSpringDynamics.velocity(
            at: 0.1, displacement: -1, initialVelocity: 3, spring: .init(mass: 1, stiffness: 100, damping: 20)
        )
        let frequency = 100.0.squareRoot()
        let restoring = frequency * 3 + 100 * -1
        let sensitivity = exp(-frequency * 0.1) / 2
            * (0.1 * abs(3 - restoring * 0.1) + 3 * 0.1
                + 2 * frequency * (3 * 0.1 * 0.1 / 2 + abs(restoring) * 0.1 * 0.1 * 0.1 / 6))
        for damping in [20 - 1e-9, 20 + 1e-9] {
            let nearby = ShellSpringDynamics.velocity(
                at: 0.1, displacement: -1, initialVelocity: 3, spring: .init(mass: 1, stiffness: 100, damping: damping)
            )
            XCTAssertEqual(nearby, critical, accuracy: sensitivity * abs(damping - 20))
        }
    }

    func testStrongOverdampingDoesNotOverflowAtLongElapsedTimes() {
        let (slow, fast) = (-1.0 / 16, -2500.0)
        let spring = ShellSpringDynamics.Parameters(mass: 1, stiffness: slow * fast, damping: -(slow + fast))
        let velocity = ShellSpringDynamics.velocity(
            at: 50, displacement: -1, initialVelocity: 0, spring: spring
        )
        let interval = slow - fast
        XCTAssertEqual(velocity, exp(slow * 50) * (fast * (expm1(-interval * 50) / interval) * -slow))
        XCTAssertEqual(ShellSpringDynamics.velocity(
            at: 1e9, displacement: -1, initialVelocity: 0, spring: spring
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
        XCTAssertEqual(reversed, -forward)
        XCTAssertEqual(scaled, forward)
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
            XCTAssertEqual(undamped, time == 0 ? -3 : exp(-0.0 * time) * (-3 * cos(2 * time) + 2 * sin(2 * time)))
            let critical = ShellSpringDynamics.position(
                at: time, displacement: -3, initialVelocity: 4, spring: .init(mass: 2, stiffness: 8, damping: 8)
            )
            XCTAssertEqual(critical, time == 0 ? -3 : exp(-2 * time) * (-3 - 2 * time))
            let overdamped = ShellSpringDynamics.position(
                at: time, displacement: -3, initialVelocity: 4, spring: .init(mass: 2, stiffness: 18, damping: 20)
            )
            XCTAssertEqual(overdamped, time == 0 ? -3 : exp(-time) * (-3 - expm1(-8 * time) / 8))
        }
    }

    func testPositionMatchesPleamarSemiImplicitEulerForDeskDripAndFollowSprings() {
        let step = 0.0005
        let steps = 3000
        let horizon = Double(steps) * step
        let steppedSpringRoundings = 30
        let closedFormRoundings = 25
        let sampleRoundings = 2
        for (stiffness, damping) in [(300.0, 20.0), (170.0, 18.0), (304.6, 34.9)] {
            let drag = damping + stiffness * step
            let center = 1 - step * drag / 2
            let discriminant = stiffness - drag * drag / 4
            let spread = step * abs(discriminant).squareRoot() / center
            let warp = (discriminant < 0 ? atanh(spread) : atan(spread)) / spread / center
            let decay = -log1p(-damping * step) / step / 2
            let stepped = ShellSpringDynamics.Parameters(
                mass: 1, stiffness: decay * decay + discriminant * warp * warp, damping: 2 * decay
            )
            let launch = decay - (damping - stiffness * step) * warp / 2
            let radius = discriminant < 0
                ? center + step * (-discriminant).squareRoot()
                : (1 - damping * step).squareRoot()
            let frequency = stepped.stiffness.squareRoot()
            let rate = stepped.damping + frequency
            let sensitivity = (1 + (abs(launch) + rate) * horizon) * (1 + rate * horizon)
                * (frequency + decay) / abs(frequency - decay)
            var value = 0.0
            var speed = 0.0
            var largestValue = 1.0
            var largestSpeed = 0.0
            var worst = 0.0
            for index in 1 ... steps {
                let force = -stiffness * (value - 1) - damping * speed
                speed += force * step
                value += speed * step
                largestValue = max(largestValue, abs(value))
                largestSpeed = max(largestSpeed, abs(speed), abs(force) * step)
                let exact = 1 + ShellSpringDynamics.position(
                    at: Double(index) * step, displacement: -1, initialVelocity: launch, spring: stepped
                )
                worst = max(worst, abs(exact - value))
            }
            let carried = 1 + (2 + radius) / ((1 - radius) * (1 - radius))
            let perStepRounding = Double.rounding(operations: 2, at: max(largestValue, largestSpeed * step))
                + step * Double.rounding(operations: 6, at: max(largestSpeed, stiffness * step * largestValue))
            let closedFormRounding = Double.rounding(
                operations: steppedSpringRoundings + closedFormRoundings + sampleRoundings, at: sensitivity
            )
            XCTAssertLessThanOrEqual(
                worst, carried * perStepRounding + closedFormRounding, "\(stiffness):\(damping)"
            )
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
        let decay = spring.damping / 2
        let overshoot = exp(-Double.pi * decay / sqrt(spring.stiffness - decay * decay))
        XCTAssertEqual(peak.value, 1 + overshoot, accuracy: spring.stiffness * overshoot * pow(0.0001 / 2, 2) / 2)
        XCTAssertEqual(peak.time, 0.3330)
    }

    func testPositionAndVelocityMatchIndependentIntegrationInEveryDampingRegime() {
        for (stiffness, damping) in [(300.0, 20.0), (304.6, 34.9), (100.0, 20.0), (100.0, 50.0)] {
            let spring = ShellSpringDynamics.Parameters(mass: 1, stiffness: stiffness, damping: damping)
            for time in [0.01, 0.05, 0.12, 0.3, 0.7] {
                let expected = integrate(
                    duration: time, displacement: -1, velocity: 3, mass: 1, stiffness: stiffness, damping: damping
                )
                let position = ShellSpringDynamics.position(
                    at: time, displacement: -1, initialVelocity: 3, spring: spring
                )
                let velocity = ShellSpringDynamics.velocity(
                    at: time, displacement: -1, initialVelocity: 3, spring: spring
                )
                XCTAssertEqual(position, expected.position, accuracy: expected.positionBound, "\(stiffness):\(damping)")
                XCTAssertEqual(velocity, expected.velocity, accuracy: expected.velocityBound, "\(stiffness):\(damping)")
            }
        }
    }

    func testNativeSpringMappingMatchesVitreusParameters() throws {
        func native(_ response: Double, _ bounce: Double) throws -> ShellSpringDynamics.Parameters {
            try XCTUnwrap(ShellSpringDynamics.Parameters(
                ShellAnimation(motion: .spring(response: response, bounce: bounce), speed: 1)
            ))
        }
        func stated(stiffness: Double, damping: Double) -> (response: Double, bounce: Double) {
            let frequency = stiffness.squareRoot()
            return (
                (2 * Double.pi / frequency * 1000).rounded() / 1000,
                ((1 - damping / (2 * frequency)) * 100).rounded() / 100
            )
        }
        for (stiffness, damping, response, bounce) in [
            (300.0, 20.0, 0.363, 0.42),
            (170.0, 18.0, 0.482, 0.31),
            (305.0, 34.9, 0.360, 0.0)
        ] {
            let design = stated(stiffness: stiffness, damping: damping)
            XCTAssertEqual(design.response, response)
            XCTAssertEqual(design.bounce, bounce)
            let spring = try native(response, bounce)
            XCTAssertEqual(spring.mass, 1)
            let played = stated(stiffness: spring.stiffness, damping: spring.damping)
            XCTAssertEqual(played.response, response)
            XCTAssertEqual(played.bounce, bounce)
        }
        XCTAssertNil(ShellSpringDynamics.Parameters(ShellAnimation(motion: .ease, speed: 1)))
    }

    private struct Integration {
        let position: Double
        let velocity: Double
        let positionBound: Double
        let velocityBound: Double
    }

    private func integrate(
        duration: Double,
        displacement: Double,
        velocity: Double,
        mass: Double,
        stiffness: Double,
        damping: Double
    ) -> Integration {
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
        let frequency = (stiffness / mass).squareRoot()
        let reach = step * (frequency + damping / mass)
        let truncation = pow(reach, 5) / 120 * exp(reach)
        let rounding = Double.ulpOfOne / 2 * ((1 + 2 * reach) * stepRounding(reach: reach) + reach)
        let energy = hypot(frequency * displacement, velocity)
        let bound = energy * expm1(Double(steps) * (truncation + rounding))
        return Integration(position: position, velocity: speed, positionBound: bound / frequency, velocityBound: bound)
    }

    private func stepRounding(reach: Double) -> Double {
        let accelerationOperations = 3.0
        let partialSums = 3.0 + 5 + 6
        let scalingOperations = 2.0
        var speedErrors = [0.0]
        var slopeErrors = [accelerationOperations]
        for weight in [reach / 2, reach / 2, reach] {
            let speedError = 1 + weight * (slopeErrors[slopeErrors.count - 1] + 1)
            let positionError = 1 + weight * (speedErrors[speedErrors.count - 1] + 1)
            speedErrors.append(speedError)
            slopeErrors.append(max(speedError, positionError) + accelerationOperations)
        }
        func update(_ stages: [Double]) -> Double {
            let sum = stages[0] + 2 * stages[1] + 2 * stages[2] + stages[3] + partialSums
            return 1 + reach * (sum / 6 + scalingOperations)
        }
        return hypot(update(speedErrors), update(slopeErrors))
    }
}
