// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class AnimationSpeedTests: XCTestCase {
    func testDefaultSpeedPreservesOriginalCurves() {
        XCTAssertEqual(MotionSnapshot.enabled.scaled(SpringConfig.default), .default)
        let cubic = MotionSnapshot.enabled.scaled(CubicConfig.hyprlandDwindle)
        XCTAssertEqual(cubic.duration, CubicConfig.hyprlandDwindle.duration)
        XCTAssertEqual(cubic.controlPoint1, CubicConfig.hyprlandDwindle.controlPoint1)
        XCTAssertEqual(cubic.controlPoint2, CubicConfig.hyprlandDwindle.controlPoint2)
    }

    func testSpeedScalesSpringTrajectoryAndCompletionWithoutChangingDamping() {
        let config = SpringConfig.default
        let baseline = SpringAnimation(from: 0, to: 300, startTime: 0, config: config)
        for speed in [0.25, 2, 4] {
            let scaled = MotionSnapshot(animationsEnabled: true, animationSpeed: speed).scaled(config)
            XCTAssertEqual(scaled.dampingRatio, config.dampingRatio)
            let animation = SpringAnimation(from: 0, to: 300, startTime: 0, config: scaled)
            for elapsed in [0.01, 0.05, 0.1, 0.3, 0.6] {
                XCTAssertEqual(animation.value(at: elapsed / speed), baseline.value(at: elapsed))
                XCTAssertEqual(
                    animation.velocity(at: elapsed / speed),
                    baseline.velocity(at: elapsed) * speed
                )
                XCTAssertEqual(animation.isComplete(at: elapsed / speed), baseline.isComplete(at: elapsed))
            }
        }
    }

    func testRetargetPreservesPositionAndVelocityWhenSpeedChanges() {
        let original = SpringAnimation(from: 0, to: 500, startTime: 0)
        let position = original.value(at: 0.08)
        let velocity = original.velocity(at: 0.08)
        let retarget = SpringAnimation(
            from: position, to: 800, initialVelocity: velocity, startTime: 0.08,
            config: MotionSnapshot(animationsEnabled: true, animationSpeed: 4).scaled(.default)
        )
        XCTAssertEqual(retarget.value(at: 0.08), position, accuracy: 0.000001)
        XCTAssertEqual(retarget.velocity(at: 0.08), velocity, accuracy: 0.000001)
        XCTAssertEqual(retarget.value(at: 1), 800)
        XCTAssertTrue(retarget.isComplete(at: 1))
    }

    func testViewportFocusAndRestoreScaleSuppliedConfigOnce() {
        let motion = MotionSnapshot(animationsEnabled: true, animationSpeed: 2)
        var state = ViewportState()
        state.animateToOffset(300, motion: motion, config: .niriWindowMovement)
        XCTAssertEqual(state.offsetTransition.kind, .spring(motion.scaled(.niriWindowMovement)))
        state.animateViewOffsetRestore(100, motion: motion)
        XCTAssertEqual(state.offsetTransition.kind, .spring(motion.scaled(.niriHorizontalViewMovement)))
        state.animateToOffset(0, motion: MotionSnapshot(animationsEnabled: false, animationSpeed: 4))
        XCTAssertEqual(state.offsetTransition.kind, .jump)
    }

    func testNiriWindowMovementAndColumnResizeUseSpeed() throws {
        let engine = NiriLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 1, windowId: 1)
        let window = engine.addWindow(token: token, to: workspace, afterSelection: nil)
        let column = try XCTUnwrap(engine.columns(in: workspace).first)
        let motion = MotionSnapshot(animationsEnabled: true, animationSpeed: 2)
        let oldFrame = CGRect(x: 100, y: 100, width: 500, height: 600)
        XCTAssertTrue(engine.triggerMoveAnimations(
            in: workspace, oldFrames: [token: oldFrame], newFrames: [token: oldFrame.offsetBy(dx: 100, dy: 100)],
            motion: motion
        ))
        XCTAssertEqual(window.moveXAnimation?.animation.config, motion.scaled(engine.windowMovementAnimationConfig))
        XCTAssertEqual(window.moveYAnimation?.animation.config, motion.scaled(engine.windowMovementAnimationConfig))

        column.cachedWidth = 500
        var state = ViewportState()
        engine.setContainerPrimarySpan(
            column, change: .setFixed(700),
            context: .init(
                workspaceId: workspace, motion: motion,
                workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 800), gaps: 12, orientation: .horizontal
            ), state: &state
        )
        XCTAssertEqual(column.widthAnimation?.config, motion.scaled(engine.windowMovementAnimationConfig))
        XCTAssertEqual(column.targetWidth, 700)
    }

    func testDwindleMovementAndResizeRunAtScaledDuration() throws {
        let oldFrame = CGRect(x: 100, y: 100, width: 500, height: 600)
        let newFrame = CGRect(x: 200, y: 200, width: 700, height: 400)
        let baseline = CubicAnimation(from: 0, to: 1, startTime: 0, config: .hyprlandDwindle)
        for speed in [0.25, 1, 2, 4] {
            let engine = DwindleLayoutEngine()
            let workspace = WorkspaceDescriptor.ID()
            let token = WindowToken(pid: 1, windowId: 1)
            _ = engine.addWindow(token: token, to: workspace, activeWindowFrame: nil)
            engine.animateWindowMovements(
                .init(oldFrames: [token: oldFrame], previousTargetFrames: [:], newFrames: [token: newFrame]),
                in: workspace, startTime: 0, motion: .init(animationsEnabled: true, animationSpeed: speed)
            )
            let node = try XCTUnwrap(engine.findNode(for: token, in: workspace))
            let frame = try XCTUnwrap(node.presentedFrame(at: 0.1 / speed))
            let progress = baseline.value(at: 0.1)
            XCTAssertEqual(frame.minX, oldFrame.minX + 100 * progress)
            XCTAssertEqual(frame.width, oldFrame.width + 200 * progress)
            XCTAssertFalse(node.hasActiveAnimations(at: 0.2 / speed))
        }
    }

    func testWorkspaceSwipeSpeedChangesSettlingWithoutChangingTrackingOrDestination() {
        func makeMotion() -> WorkspaceSwipeMotion {
            let motion = WorkspaceSwipeMotion(cumulativeUnits: 0, timestamp: 1)
            motion.update(cumulativeUnits: 180, timestamp: 1.1)
            return motion
        }
        let baseline = makeMotion()
        baseline.release(timestamp: 1.3, allowFlick: true, animationTime: 0)
        for speed in [0.25, 2, 4] {
            let motion = makeMotion()
            XCTAssertEqual(motion.progress(at: 1.1), 0.6)
            motion.release(
                timestamp: 1.3, allowFlick: true, animationTime: 0,
                motion: .init(animationsEnabled: true, animationSpeed: speed)
            )
            XCTAssertEqual(motion.target, baseline.target)
            for elapsed in [0.01, 0.1, 0.3, 0.6] {
                XCTAssertEqual(motion.progress(at: elapsed / speed), baseline.progress(at: elapsed))
                XCTAssertEqual(motion.isComplete(at: elapsed / speed), baseline.isComplete(at: elapsed))
            }
        }
    }
}
