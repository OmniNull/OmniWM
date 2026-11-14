// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class EdgeScrollAnimationTests: XCTestCase {
    private let workspaceId = WorkspaceDescriptor.ID()

    private func startEdgeScroll(
        _ driver: AnimationDriver,
        from offset: CGFloat,
        to limit: CGFloat,
        at time: TimeInterval
    ) {
        var previous = ViewportState()
        previous.viewOffset = offset
        var next = previous
        next.edgeScrollOffset(to: limit, speed: 1000)
        XCTAssertTrue(next.hasPendingOffsetAnimation)
        driver.reconcileViewportCommit(
            workspaceId: workspaceId,
            previous: previous,
            next: next,
            transition: next.offsetTransition,
            at: time
        )
    }

    func testMovesAtASteadySpeedFromTheFirstFrame() {
        let animation = EdgeScrollAnimation(from: 0, to: 2000, speed: 1000, startTime: 10)

        let samples = (0 ... 5).map { animation.value(at: 10 + Double($0) / 60) }
        let steps = zip(samples.dropFirst(), samples).map { $0 - $1 }

        XCTAssertEqual(samples[0], 0, accuracy: 0.001)
        for step in steps {
            XCTAssertEqual(step, 1000.0 / 60, accuracy: 0.001)
        }
        XCTAssertEqual(animation.velocity(at: 10.5), 1000)
    }

    func testStopsExactlyAtTheLimitInEitherDirection() {
        let trailing = EdgeScrollAnimation(from: 100, to: 400, speed: 1000, startTime: 0)
        XCTAssertFalse(trailing.isComplete(at: 0.29))
        XCTAssertEqual(trailing.value(at: 0.2), 300, accuracy: 0.001)
        XCTAssertEqual(trailing.value(at: 5), 400)
        XCTAssertTrue(trailing.isComplete(at: 0.3))
        XCTAssertEqual(trailing.velocity(at: 0.3), 0)

        let leading = EdgeScrollAnimation(from: 100, to: -200, speed: 1000, startTime: 0)
        XCTAssertEqual(leading.value(at: 0.1), 0, accuracy: 0.001)
        XCTAssertEqual(leading.velocity(at: 0.1), -1000)
        XCTAssertEqual(leading.value(at: 5), -200)
    }

    func testDriverRendersTheLiveOffsetAndRemovesTheMotionAtTheLimit() {
        let driver = AnimationDriver()
        startEdgeScroll(driver, from: 0, to: 500, at: 100)

        XCTAssertTrue(driver.hasEdgeScroll(in: workspaceId))
        XCTAssertEqual(
            driver.liveViewOffset(in: workspaceId, semanticOffset: 500, at: 100.2) ?? 0,
            200,
            accuracy: 0.001
        )
        XCTAssertEqual(driver.tickResult(in: workspaceId, at: 100.4), .running)
        XCTAssertEqual(driver.tickResult(in: workspaceId, at: 100.5), .inactive)
        XCTAssertFalse(driver.hasMotion(in: workspaceId))
    }

    func testAJumpCommitStopsTheEdgeScroll() {
        let driver = AnimationDriver()
        startEdgeScroll(driver, from: 0, to: 500, at: 100)

        var previous = ViewportState()
        previous.viewOffset = 500
        var next = previous
        next.jumpOffset(to: 120)
        driver.reconcileViewportCommit(
            workspaceId: workspaceId,
            previous: previous,
            next: next,
            transition: next.offsetTransition,
            at: 100.12
        )

        XCTAssertFalse(driver.hasEdgeScroll(in: workspaceId))
    }

    func testARebaseShiftsTheWholeScroll() {
        let driver = AnimationDriver()
        startEdgeScroll(driver, from: 0, to: 500, at: 100)
        var previous = ViewportState()
        previous.viewOffset = 500
        var next = previous
        next.rebaseOffset(by: 40)

        driver.reconcileViewportCommit(
            workspaceId: workspaceId,
            previous: previous,
            next: next,
            transition: next.offsetTransition,
            at: 100.1
        )

        let animation = driver.edgeScroll(in: workspaceId)
        XCTAssertEqual(animation?.value(at: 100.1) ?? 0, 140, accuracy: 0.001)
        XCTAssertEqual(animation?.value(at: 200) ?? 0, 540, accuracy: 0.001)
    }
}
