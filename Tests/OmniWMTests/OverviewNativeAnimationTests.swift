// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class OverviewNativeAnimationTests: XCTestCase {
    func testNativeTransitionMatchesMissionControlCriticalSpring() {
        let transition = OverviewNativeTransition(generation: 1, startTime: 100, from: 0, to: 1)
        let frequency = 2 * Double.pi / OverviewNativeTransition.response
        let reference = SpringAnimation(
            from: 0,
            to: 1,
            startTime: 100,
            config: SpringConfig(dampingRatio: 1, stiffness: frequency * frequency, epsilon: 0.001)
        )

        for elapsed in [0.0, 0.01, 0.04, 0.1, 0.2] {
            XCTAssertEqual(
                transition.value(at: 100 + elapsed),
                reference.value(at: 100 + elapsed)
            )
            XCTAssertEqual(
                transition.velocity(at: 100 + elapsed),
                reference.velocity(at: 100 + elapsed),
                accuracy: Double.rounding(operations: 8, at: frequency * (1 + frequency * elapsed))
            )
        }
        let animation = transition.makeAnimation(keyPath: "position")
        XCTAssertEqual(transition.response, 0.25)
        XCTAssertEqual(animation.mass, 1)
        XCTAssertEqual(animation.stiffness, 64 * Double.pi * Double.pi)
        XCTAssertEqual(animation.damping, 16 * Double.pi)
        XCTAssertEqual(animation.beginTime, 100)
        XCTAssertEqual(animation.settlingDuration, 0.4)
        XCTAssertEqual(animation.duration, transition.duration)
        XCTAssertEqual(transition.duration, animation.settlingDuration)
    }

    func testChromeExitSpringUsesHalfResponse() {
        let transition = OverviewNativeTransition(generation: 1, startTime: 100, from: 1, to: 0, initialVelocity: -0.5)
        XCTAssertEqual(transition.chromeExitResponse, 0.125)
        XCTAssertNil(OverviewNativeTransition(generation: 1, startTime: 100, from: 0, to: 1).chromeExitResponse)

        let animation = transition.makeAnimation(keyPath: "opacity", response: transition.chromeExitResponse)
        XCTAssertEqual(animation.stiffness, 256 * Double.pi * Double.pi)
        XCTAssertEqual(animation.damping, 32 * Double.pi)
        XCTAssertEqual(animation.duration, animation.settlingDuration)
        XCTAssertEqual(animation.duration, 0.2)
        XCTAssertEqual(animation.beginTime, 100)
        XCTAssertEqual(animation.initialVelocity, transition.makeAnimation(keyPath: "opacity").initialVelocity)
    }

    func testReleaseHandoffHasNoPositionOrVelocityDiscontinuity() {
        for progress in [0.05, 0.2, 0.38, 0.5, 0.65, 0.82, 0.95] {
            for velocity in [-4.0, -2.5, -0.5, 0, 0.2, 1.8, 3.5, 6] {
                for target in [0.0, 1] {
                    let transition = OverviewNativeTransition(
                        generation: 1,
                        startTime: 100,
                        from: progress,
                        to: target,
                        initialVelocity: velocity
                    )
                    XCTAssertEqual(transition.value(at: 100), target + (progress - target))
                    XCTAssertEqual(transition.velocity(at: 100), velocity)
                    XCTAssertLessThanOrEqual(transition.duration, 0.6)
                    XCTAssertEqual(transition.value(at: 101 + transition.duration), target)
                    XCTAssertEqual(transition.velocity(at: 101 + transition.duration), 0)
                }
            }
        }
        let normalized = OverviewNativeTransition(generation: 1, startTime: 0, from: 0.4, to: 1, initialVelocity: 1.2)
        XCTAssertEqual(normalized.makeAnimation(keyPath: "opacity").initialVelocity, 2)
        for (startTime, initialVelocity) in [(100.0, 0.0), (0.0, 5.0)] {
            let settled = OverviewNativeTransition(
                generation: 1, startTime: startTime, from: 1, to: 1, initialVelocity: initialVelocity
            )
            XCTAssertEqual(settled.makeAnimation(keyPath: "opacity").initialVelocity, 0)
            XCTAssertEqual(settled.duration, 0)
            XCTAssertEqual(settled.value(at: startTime), 1)
            XCTAssertEqual(settled.velocity(at: startTime), 0)
        }
    }

    func testRubberBandMatchesHyperbolicResistance() {
        for progress in [0.0, 0.5, 1] {
            XCTAssertEqual(OverviewNativeTransition.rubberBand(progress), progress)
            XCTAssertEqual(OverviewNativeTransition.rubberBandInverse(progress), progress)
        }
        XCTAssertEqual(OverviewNativeTransition.rubberBand(1.1), 1.0464788732394366)
        XCTAssertEqual(
            OverviewNativeTransition.rubberBand(1.1),
            1 - OverviewNativeTransition.rubberBand(-(1.1 - 1))
        )
        let coefficient = 0.55
        let dimension = 0.30
        let step = 0.000001
        XCTAssertEqual(
            (OverviewNativeTransition.rubberBand(1 + step) - 1) / step,
            coefficient,
            accuracy: coefficient * coefficient * step / dimension + Double.rounding(operations: 2, at: 1 + step) / step
        )
        XCTAssertEqual(
            OverviewNativeTransition.rubberBand(1_000_000),
            1 + dimension,
            accuracy: dimension * dimension / (coefficient * 999_999)
        )
        XCTAssertEqual(
            OverviewNativeTransition.rubberBand(-1_000_000),
            -dimension,
            accuracy: dimension * dimension / (coefficient * 1_000_000)
        )
        for raw in [-1_000_000_000.0, -5, -1, -0.5, 1.5, 2, 5, 1_000_000_000] {
            let progress = OverviewNativeTransition.rubberBand(raw)
            XCTAssertGreaterThanOrEqual(progress, -0.3)
            XCTAssertLessThanOrEqual(progress, 1.3)
        }
        for excess in [0.01, 0.05, 0.1, 0.25, 0.8, 2.0] {
            let slope = (dimension + coefficient * excess) * (dimension + coefficient * excess) /
                (coefficient * dimension * dimension)
            XCTAssertEqual(
                OverviewNativeTransition.rubberBandInverse(OverviewNativeTransition.rubberBand(1 + excess)),
                1 + excess,
                accuracy: slope * Double.rounding(operations: 2, at: 1 + dimension) + Double.rounding(
                    operations: 5,
                    at: 1 + excess
                )
            )
            XCTAssertEqual(
                OverviewNativeTransition.rubberBandInverse(OverviewNativeTransition.rubberBand(-excess)),
                -excess,
                accuracy: slope * Double.rounding(operations: 5, at: dimension) + Double.rounding(
                    operations: 4,
                    at: excess
                )
            )
        }
        XCTAssertTrue(OverviewNativeTransition.rubberBandInverse(1.35).isFinite)
        XCTAssertTrue(OverviewNativeTransition.rubberBandInverse(-0.35).isFinite)
    }

    func testReleaseTargetFollowsProjectedMomentumAndFlicks() {
        for (progress, velocity, target) in [
            (0.49, 0.0, 0.0),
            (0.51, 0, 1),
            (0.5, 0, 1),
            (0.25, 2, 1),
            (0.75, -2, 0),
            (0.2, 2.5, 1),
            (0.8, -2.5, 0),
            (0.4, 0.49, 0),
            (0.45, 0.4, 1),
            (0.3, 0.5, 1),
            (0.7, -0.5, 0),
            (1.1, -3, 1),
            (-0.1, 3, 0)
        ] {
            XCTAssertEqual(
                OverviewNativeTransition.releaseTarget(progress: progress, velocity: velocity),
                target,
                "progress \(progress) velocity \(velocity)"
            )
        }
    }

    func testReleaseVelocityCompressesResponse() {
        XCTAssertEqual(OverviewNativeTransition.compressedResponse(forReleaseVelocity: 0), 0.25)
        XCTAssertEqual(
            OverviewNativeTransition.compressedResponse(forReleaseVelocity: 0.5),
            0.25 * (1 - 0.25 * tanh(1))
        )
        XCTAssertEqual(
            OverviewNativeTransition.compressedResponse(forReleaseVelocity: -50),
            0.1875
        )
        let transition = OverviewNativeTransition(
            generation: 1,
            startTime: 0,
            from: 0.3,
            to: 1,
            initialVelocity: 3,
            response: 0.2
        )
        let frequency = CGFloat(2 * Double.pi / 0.2)
        XCTAssertEqual(transition.makeAnimation(keyPath: "opacity").stiffness, frequency * frequency)
        XCTAssertEqual(transition.value(at: 0), 1 + (0.3 - 1))
        XCTAssertEqual(transition.velocity(at: 0), 3)
    }

    func testNativeReversalPreservesCurrentProgressAndVelocity() {
        let opening = OverviewNativeTransition(generation: 1, startTime: 100, from: 0, to: 1)
        let reversedAt = 100.06
        let closing = OverviewNativeTransition(
            generation: 2,
            startTime: reversedAt,
            from: opening.value(at: reversedAt),
            to: 0,
            initialVelocity: opening.velocity(at: reversedAt)
        )

        XCTAssertEqual(closing.value(at: reversedAt), opening.value(at: reversedAt))
        XCTAssertEqual(closing.velocity(at: reversedAt), opening.velocity(at: reversedAt))
        XCTAssertLessThan(closing.makeAnimation(keyPath: "opacity").initialVelocity, 0)
        XCTAssertEqual(closing.value(at: reversedAt + closing.duration + 1), 0)
        XCTAssertEqual(closing.velocity(at: reversedAt + closing.duration + 1), 0)
    }

    func testNativeLayerMotionCommitsFinalModelAndAnimatesFromCapturedGeometry() throws {
        let layer = CALayer()
        layer.position = CGPoint(x: 400, y: 300)
        layer.bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        layer.opacity = 0
        let captured = OverviewLayerMotion(layer)
        let transition = OverviewNativeTransition(generation: 1, startTime: 100, from: 0, to: 1)
        let destination = CGPoint(x: 200, y: 200)
        let destinationBounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        layer.position = destination
        layer.bounds = destinationBounds
        layer.opacity = 1

        captured.apply(transition, at: 100, replacing: true)

        let position = try XCTUnwrap(layer.animation(forKey: "overview.position") as? CASpringAnimation)
        let bounds = try XCTUnwrap(layer.animation(forKey: "overview.bounds") as? CASpringAnimation)
        let opacity = try XCTUnwrap(layer.animation(forKey: "overview.opacity") as? CASpringAnimation)
        XCTAssertEqual((position.fromValue as? NSValue)?.pointValue, CGPoint(x: 400, y: 300))
        XCTAssertEqual((position.toValue as? NSValue)?.pointValue, destination)
        XCTAssertEqual((bounds.fromValue as? NSValue)?.rectValue, CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual((bounds.toValue as? NSValue)?.rectValue, destinationBounds)
        XCTAssertEqual((opacity.fromValue as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual((opacity.toValue as? NSNumber)?.doubleValue, 1)
        XCTAssertEqual(layer.position, destination)
        XCTAssertEqual(layer.bounds, destinationBounds)
        XCTAssertEqual(layer.opacity, 1)
        XCTAssertEqual(position.beginTime + position.duration, transition.startTime + transition.duration)
    }

    func testLateGeometryRerouteKeepsFiniteEndpointsAndOriginalDeadline() throws {
        let layer = CALayer()
        let current = CGPoint(x: 400, y: 300)
        let destination = CGPoint(x: -700, y: 1000)
        layer.position = current
        layer.bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let captured = OverviewLayerMotion(layer)
        let transition = OverviewNativeTransition(generation: 1, startTime: 100, from: 0, to: 1)
        let deadline = transition.startTime + transition.duration
        let eventTime = deadline - 0.001
        layer.position = destination

        captured.apply(transition, at: eventTime, replacing: false)

        let position = try XCTUnwrap(layer.animation(forKey: "overview.position") as? CASpringAnimation)
        XCTAssertEqual((position.fromValue as? NSValue)?.pointValue, current)
        XCTAssertEqual((position.toValue as? NSValue)?.pointValue, destination)
        XCTAssertEqual(position.beginTime, eventTime)
        XCTAssertEqual(position.beginTime + position.duration, deadline)
        XCTAssertGreaterThan(position.stiffness, transition.makeAnimation(keyPath: "position").stiffness)
        XCTAssertTrue(position.stiffness.isFinite)
        XCTAssertTrue(position.damping.isFinite)
        XCTAssertEqual(position.initialVelocity, 0)
        XCTAssertNil(layer.animation(forKey: "overview.bounds"))

        let settled = OverviewLayerMotion(layer)
        layer.position = .zero
        settled.apply(transition, at: deadline, replacing: false)
        XCTAssertNil(layer.animation(forKey: "overview.position"))
        XCTAssertEqual(layer.position, .zero)
    }

    func testReversalBeforeFirstLayerCommitPreservesUnpresentedStartGeometry() throws {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let layer = CALayer()
        let initialPosition = CGPoint(x: 10, y: 20)
        let initialBounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        layer.position = initialPosition
        layer.bounds = initialBounds
        layer.opacity = 0
        let now = CACurrentMediaTime()
        let initial = OverviewLayerMotion(layer)
        let opening = OverviewNativeTransition(generation: 1, startTime: now, from: 0, to: 1)
        layer.position = CGPoint(x: 100, y: 200)
        layer.bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        layer.opacity = 1
        initial.apply(opening, at: now, replacing: true)
        XCTAssertNil(layer.presentation())

        let reversed = OverviewLayerMotion(layer)
        layer.position = CGPoint(x: 30, y: 40)
        layer.bounds = CGRect(x: 0, y: 0, width: 700, height: 500)
        layer.opacity = 0.25
        let closing = OverviewNativeTransition(generation: 2, startTime: now, from: 1, to: 0)
        reversed.apply(closing, at: now, replacing: true)

        let position = try XCTUnwrap(layer.animation(forKey: "overview.position") as? CASpringAnimation)
        let bounds = try XCTUnwrap(layer.animation(forKey: "overview.bounds") as? CASpringAnimation)
        let opacity = try XCTUnwrap(layer.animation(forKey: "overview.opacity") as? CASpringAnimation)
        XCTAssertEqual((position.fromValue as? NSValue)?.pointValue, initialPosition)
        XCTAssertEqual((bounds.fromValue as? NSValue)?.rectValue, initialBounds)
        XCTAssertEqual((opacity.fromValue as? NSNumber)?.doubleValue, 0)
    }
}
