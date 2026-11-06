// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class WorkspaceSwipeMotionTests: XCTestCase {
    func testRecognitionMovementCommitsSingleFrameFlickWithoutProgressJump() {
        let motion = WorkspaceSwipeMotion(
            cumulativeUnits: 150, timestamp: 1.03125,
            recognitionMovement: SwipeEvent(delta: 150, timestamp: 1)
        )

        XCTAssertEqual(motion.progress(at: 1.03125), 0)
        XCTAssertEqual(motion.velocity(at: 1.03125), 150 / WorkspaceSwipeMotion.travelUnits / (1.03125 - 1))
        XCTAssertTrue(motion.release(timestamp: 1.0625, allowFlick: true, animationTime: 100))
        XCTAssertEqual(motion.target, 1)
        XCTAssertEqual(motion.velocity(at: 100), 150 / WorkspaceSwipeMotion.travelUnits / (1.0625 - 1))
    }

    func testSlowRecognitionUsesRecentMovementInsteadOfWholeContactDisplacement() {
        let motion = WorkspaceSwipeMotion(
            cumulativeUnits: 20, timestamp: 2,
            recognitionMovement: SwipeEvent(delta: 2, timestamp: 1.95)
        )

        XCTAssertEqual(motion.velocity(at: 2), 2 / WorkspaceSwipeMotion.travelUnits / (2 - 1.95))
        XCTAssertTrue(motion.release(timestamp: 2.01, allowFlick: true, animationTime: 100))
        XCTAssertEqual(motion.target, 0)
        XCTAssertTrue(motion.isComplete(at: 100))
    }

    func testRecognitionVelocityExpiresWithItsStartingSample() {
        for releaseTime in [1.16, 1.30] {
            let motion = WorkspaceSwipeMotion(
                cumulativeUnits: 20, timestamp: 1.1,
                recognitionMovement: SwipeEvent(delta: 20, timestamp: 1)
            )

            XCTAssertTrue(motion.release(timestamp: releaseTime, allowFlick: true, animationTime: 100))
            XCTAssertEqual(motion.target, 0)
            XCTAssertEqual(motion.velocity(at: 100), 0)
        }
    }

    func testInvalidRecognitionIntervalDoesNotSeedVelocity() {
        for previousTime in [Double.nan, -Double.infinity, 1, 1.1] {
            let motion = WorkspaceSwipeMotion(
                cumulativeUnits: 180, timestamp: 1,
                recognitionMovement: SwipeEvent(delta: 180, timestamp: previousTime)
            )
            XCTAssertEqual(motion.velocity(at: 1), 0)
            motion.release(timestamp: 1.01, allowFlick: true, animationTime: 100)
            XCTAssertEqual(motion.target, 0)
        }
    }

    func testTrackingStartsAtRecognitionBaselineAndFollowsFinger() {
        let motion = WorkspaceSwipeMotion(cumulativeUnits: 24, timestamp: 1)

        XCTAssertEqual(motion.progress(at: 1), 0)
        XCTAssertTrue(motion.update(cumulativeUnits: 174, timestamp: 1.1))
        XCTAssertEqual(motion.progress(at: 1.1), 0.5)
        XCTAssertTrue(motion.update(cumulativeUnits: 324, timestamp: 1.2))
        XCTAssertEqual(motion.progress(at: 1.2), 1)
        XCTAssertNil(motion.target)
        XCTAssertFalse(motion.isComplete(at: 5))
    }

    func testReversalCancelsAfterCrossingHalfway() {
        let motion = WorkspaceSwipeMotion(cumulativeUnits: 0, timestamp: 1)
        motion.update(cumulativeUnits: 210, timestamp: 1.1)
        motion.update(cumulativeUnits: 210, timestamp: 1.18)
        motion.update(cumulativeUnits: 120, timestamp: 1.25)

        XCTAssertTrue(motion.release(timestamp: 1.26, allowFlick: true, animationTime: 1.26))
        XCTAssertEqual(motion.target, 0)
        XCTAssertEqual(motion.progress(at: 1.26), 120 / WorkspaceSwipeMotion.travelUnits)
        XCTAssertEqual(motion.progress(at: 5), 0)
        XCTAssertTrue(motion.isComplete(at: 5))
    }

    func testReleaseWithoutMovementCompletesWithCancellationTarget() {
        let motion = WorkspaceSwipeMotion(cumulativeUnits: 24, timestamp: 1)

        XCTAssertTrue(motion.release(timestamp: 1.1, allowFlick: true, animationTime: 1.1))
        XCTAssertEqual(motion.target, 0)
        XCTAssertEqual(motion.progress(at: 1.1), 0)
        XCTAssertTrue(motion.isComplete(at: 1.1))
    }

    func testQuickFlickCommitsBeforeHalfway() {
        let motion = WorkspaceSwipeMotion(cumulativeUnits: 0, timestamp: 1)
        motion.update(cumulativeUnits: 60, timestamp: 1.04)

        XCTAssertTrue(motion.release(timestamp: 1.05, allowFlick: true, animationTime: 1.05))
        XCTAssertEqual(motion.target, 1)
        XCTAssertEqual(motion.progress(at: 1.05), 1 + (60 / WorkspaceSwipeMotion.travelUnits - 1))
        XCTAssertGreaterThan(motion.progress(at: 1.10), 0.2)
        XCTAssertEqual(motion.progress(at: 5), 1)
    }

    func testHeldReleaseDropsVelocityOnBothSidesOfCommitThreshold() {
        let cases: [(units: Double, update: TimeInterval, release: TimeInterval, target: Double)] = [
            (60, 1.04, 1.30, 0), (180, 1.10, 1.40, 1)
        ]
        for entry in cases {
            let motion = WorkspaceSwipeMotion(cumulativeUnits: 0, timestamp: 1)
            motion.update(cumulativeUnits: entry.units, timestamp: entry.update)
            motion.release(timestamp: entry.release, allowFlick: true, animationTime: entry.release)
            XCTAssertEqual(motion.target, entry.target)
            XCTAssertEqual(motion.velocity(at: entry.release), 0)
            if entry.target == 0 {
                XCTAssertLessThan(motion.progress(at: 1.40), 0.2)
            }
        }
    }

    func testDisallowedFlickCancelsRegardlessOfProgress() {
        let motion = WorkspaceSwipeMotion(cumulativeUnits: 0, timestamp: 1)
        motion.update(cumulativeUnits: 240, timestamp: 1.04)

        motion.release(timestamp: 1.05, allowFlick: false, animationTime: 1.05)

        XCTAssertEqual(motion.target, 0)
        XCTAssertEqual(motion.progress(at: 5), 0)
    }

    func testCatchingSpringPreservesProgressAndResetsFingerOrigin() {
        let motion = WorkspaceSwipeMotion(cumulativeUnits: 0, timestamp: 1)
        motion.update(cumulativeUnits: 90, timestamp: 1.1)
        motion.release(timestamp: 1.11, allowFlick: true, animationTime: 1.11)
        let caughtProgress = motion.progress(at: 1.16)

        XCTAssertTrue(motion.catchMotion(cumulativeUnits: 42, timestamp: 1.16, animationTime: 1.16))
        XCTAssertEqual(motion.progress(at: 1.16), caughtProgress)
        XCTAssertEqual(motion.progress(at: 2), caughtProgress)
        XCTAssertEqual(motion.velocity(at: 1.16), 0)
        XCTAssertNil(motion.target)
        XCTAssertTrue(motion.update(cumulativeUnits: 42, timestamp: 1.17))
        XCTAssertEqual(motion.progress(at: 1.17), caughtProgress)
        motion.update(cumulativeUnits: 12, timestamp: 1.18)
        XCTAssertEqual(motion.progress(at: 1.18), caughtProgress - 0.1)
    }

    func testReleaseAndCatchKeepGestureAndAnimationClocksSeparate() {
        for (gestureStart, animationStart) in [(1673.0, 288343.0), (288343.0, 1673.0)] {
            let motion = WorkspaceSwipeMotion(cumulativeUnits: 0, timestamp: gestureStart)
            motion.update(cumulativeUnits: 60, timestamp: gestureStart + 0.04)
            XCTAssertTrue(motion.release(
                timestamp: gestureStart + 0.05, allowFlick: true, animationTime: animationStart
            ))
            XCTAssertEqual(motion.target, 1)
            XCTAssertEqual(motion.progress(at: animationStart), 1 + (60 / WorkspaceSwipeMotion.travelUnits - 1))
            XCTAssertFalse(motion.isComplete(at: animationStart + 0.01))
            let caught = motion.progress(at: animationStart + 0.05)
            XCTAssertGreaterThan(caught, 0.2)
            XCTAssertLessThan(caught, 1)

            XCTAssertTrue(motion.catchMotion(
                cumulativeUnits: 20, timestamp: gestureStart + 0.10, animationTime: animationStart + 0.05
            ))
            XCTAssertEqual(motion.progress(at: animationStart + 1), caught)
            XCTAssertNil(motion.target)
            motion.update(cumulativeUnits: 20, timestamp: gestureStart + 0.11)
            XCTAssertEqual(motion.progress(at: animationStart + 1), caught)
            XCTAssertTrue(motion.release(
                timestamp: gestureStart + 0.30, allowFlick: false, animationTime: animationStart + 1
            ))
            XCTAssertFalse(motion.isComplete(at: animationStart + 1.01))
            XCTAssertTrue(motion.isComplete(at: animationStart + 2))
            XCTAssertEqual(motion.progress(at: animationStart + 2), 0)
        }
    }

    func testRubberBandResistsOverscrollOnBothEnds() {
        let motion = WorkspaceSwipeMotion(cumulativeUnits: 0, timestamp: 1)
        motion.update(cumulativeUnits: -300, timestamp: 1.1)
        let lower = motion.progress(at: 1.1)
        XCTAssertLessThan(lower, 0)
        XCTAssertGreaterThan(lower, -0.3)

        motion.update(cumulativeUnits: 600, timestamp: 1.2)
        let upper = motion.progress(at: 1.2)
        XCTAssertGreaterThan(upper, 1)
        XCTAssertLessThan(upper, 1.3)
        XCTAssertEqual(upper, 1 - lower)
        motion.update(cumulativeUnits: .greatestFiniteMagnitude, timestamp: 1.3)
        XCTAssertEqual(motion.progress(at: 1.3), 1.3)
        motion.release(timestamp: 1.31, allowFlick: true, animationTime: 1.31)
        XCTAssertTrue(WorkspaceSwipeMotion.progressBounds.contains(motion.progress(at: 1.32)))
    }

    func testCatchingOverscrollDoesNotJumpAtNextUnmovedSample() {
        let motion = WorkspaceSwipeMotion(cumulativeUnits: 0, timestamp: 1)
        motion.update(cumulativeUnits: 450, timestamp: 1.1)
        let progress = motion.progress(at: 1.1)

        motion.catchMotion(cumulativeUnits: 0, timestamp: 1.2, animationTime: 1.2)
        motion.update(cumulativeUnits: 0, timestamp: 1.3)

        XCTAssertEqual(motion.progress(at: 1.3), progress)
    }

    func testInvalidOrDecreasingInputDoesNotChangeTracking() {
        let motion = WorkspaceSwipeMotion(cumulativeUnits: 0, timestamp: 1)
        motion.update(cumulativeUnits: 90, timestamp: 1.1)

        XCTAssertFalse(motion.update(cumulativeUnits: .nan, timestamp: 1.2))
        XCTAssertFalse(motion.update(cumulativeUnits: 120, timestamp: .infinity))
        XCTAssertFalse(motion.update(cumulativeUnits: 120, timestamp: 1.09))
        XCTAssertFalse(motion.release(timestamp: .nan, allowFlick: true, animationTime: .nan))
        XCTAssertFalse(motion.release(timestamp: 1.09, allowFlick: true, animationTime: 1.09))
        XCTAssertFalse(motion.catchMotion(cumulativeUnits: .infinity, timestamp: 1.2, animationTime: 1.2))
        XCTAssertFalse(motion.catchMotion(cumulativeUnits: 0, timestamp: 1.09, animationTime: 1.09))
        XCTAssertEqual(motion.progress(at: 1.2), 0.3)
        XCTAssertNil(motion.target)
        XCTAssertTrue(motion.update(cumulativeUnits: 120, timestamp: 1.2))
        XCTAssertEqual(motion.progress(at: 1.2), 0.4)
    }

    func testReleasedMotionRejectsSamplesUntilCaughtAndInvalidQueriesStayFinite() {
        let motion = WorkspaceSwipeMotion(cumulativeUnits: 0, timestamp: 1)
        motion.update(cumulativeUnits: 90, timestamp: 1.1)
        motion.release(timestamp: 1.11, allowFlick: true, animationTime: 1.11)

        XCTAssertFalse(motion.update(cumulativeUnits: 120, timestamp: 1.2))
        XCTAssertFalse(motion.release(timestamp: 1.2, allowFlick: false, animationTime: 1.2))
        XCTAssertEqual(motion.target, 1)
        XCTAssertEqual(motion.progress(at: .nan), 0.3)
        XCTAssertEqual(motion.progress(at: 0), 1 + (90 / WorkspaceSwipeMotion.travelUnits - 1))
        XCTAssertTrue(motion.velocity(at: .infinity).isFinite)
        XCTAssertFalse(motion.isComplete(at: .nan))
    }
}
