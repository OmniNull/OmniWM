// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

extension TrackpadWindowMoveFrameTests {
    private func liveDwindleFixture(grouped: Bool = false, windows: Int = 2) throws -> Fixture {
        let count = grouped ? 3 : windows
        let fixture = try makeMoveFixture(
            .dwindle,
            grouped: grouped,
            windows: windows,
            firstWindowId: Int(CGWindowID.max) - count
        )
        let frames = fixture.initialFrames
        let refresh = fixture.controller.layoutRefreshController
        refresh.fastFrameProvider = { token, _ in frames[token] }
        let bounds = Dictionary(uniqueKeysWithValues: frames.map {
            (UInt32($0.key.windowId), ScreenCoordinateSpace.toWindowServer(rect: $0.value))
        })
        refresh.windowBoundsProvider = { ids in bounds.filter { ids.contains($0.key) } }
        return fixture
    }

    func testLiveDwindleGroupKeepsItsGrabPointAndTabsAcrossDistinctLatchedPoints() throws {
        let fixture = try liveDwindleFixture(grouped: true)
        let group = try XCTUnwrap(fixture.base.dwindle.tile(containing: fixture.moved, in: fixture.workspace))
        let members = [fixture.moved, fixture.tokens[2]]
        let grab = CGPoint(x: fixture.startFrame.midX, y: (fixture.startFrame.midY + fixture.startFrame.maxY) / 2)
        let target = fixture.targetFrame
        fixture.send(Fixture.event(location: grab, touch: fixture.startTouch, phase: .began, sample: 0))
        let middle = WindowMoveGeometry.targetFrame(in: target, direction: nil)
        let points = [middle.center, CGPoint(x: middle.midX, y: (middle.midY + middle.maxY) / 2)]
        for (index, point) in points.enumerated() {
            let touch = fixture.touch(at: point, grabbedAt: grab)
            fixture.send(Fixture.event(location: grab, touch: touch, phase: .changed, sample: index + 1))
            let carried = fixture.startFrame.offsetBy(dx: point.x - grab.x, dy: point.y - grab.y)
            let scale = fixture.controller.layoutRefreshController.buildMonitorSnapshot(for: fixture.monitor).scale
            XCTAssertEqual(
                try fixture.projection().frameChanges.first { $0.token == fixture.moved }?.frame,
                carried.roundedToPhysicalPixels(scale: scale)
            )
            XCTAssertTrue(fixture.base.dwindle.liveMoveHoldsTarget(at: point))
            XCTAssertEqual(fixture.order(), [[fixture.target], members])
            XCTAssertTrue(fixture.base.dwindle.tile(containing: fixture.moved, in: fixture.workspace) === group)
            XCTAssertEqual(group.activeToken, fixture.moved)
            let rail = try XCTUnwrap(fixture.controller.dwindleLayoutHandler.desiredTabRailInfos().first)
            XCTAssertEqual(rail.tabs.map(\.token), members.map(Optional.some))
        }
        let touch = fixture.touch(at: try XCTUnwrap(points.last), grabbedAt: grab)
        let sequence = fixture.base.manager.worldSeq
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }
        let trace = FrameApplyTrace.shared.dump()
        fixture.send(Fixture.event(location: grab, touch: touch, phase: .changed, sample: points.count + 1))
        let pressed = fixture.handler.state.leftPressLocation
        let released = fixture.handler.state.leftReleaseLocation
        fixture.handler.dispatchMouseDown(at: grab, modifiers: [], windowIdUnderPointer: fixture.moved.windowId)
        fixture.handler.dispatchMouseDragged(at: grab)
        fixture.handler.dispatchMouseUp(at: grab)
        XCTAssertEqual(fixture.handler.state.leftPressLocation, pressed)
        XCTAssertEqual(fixture.handler.state.leftReleaseLocation, released)
        XCTAssertEqual(fixture.base.manager.worldSeq, sequence)
        XCTAssertEqual(FrameApplyTrace.shared.dump(), trace)
        XCTAssertTrue(fixture.handler.state.gestureOwnsWindowInteraction)
        fixture.cancel()
        XCTAssertEqual(fixture.order(), [members, [fixture.target]])
    }

    func testLiveDwindleQueuedLayoutAndAnimationDrawTheLatestCarryAndLiftSettlesFromIt() throws {
        let fixture = try liveDwindleFixture()
        fixture.controller.motionPolicy.animationsEnabled = true
        let refresh = fixture.controller.layoutRefreshController
        let engine = fixture.base.dwindle
        let handler = fixture.controller.dwindleLayoutHandler
        fixture.begin()
        fixture.move()
        let centre = fixture.targetFrame.center
        let inside = CGPoint(x: centre.x, y: centre.y + fixture.targetFrame.height / 8)
        let touch = fixture.touch(at: inside)
        let carried = fixture.expectedFloatingFrame(at: touch)
        let sequence = fixture.base.manager.worldSeq
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }
        let queuedTrace = FrameApplyTrace.shared.dump()
        fixture.send(fixture.event(at: touch))
        XCTAssertEqual(fixture.base.manager.worldSeq, sequence)
        XCTAssertEqual(FrameApplyTrace.shared.dump(), queuedTrace)
        try executePendingRelayout(refresh)
        assertFrameSubmission(fixture.moved, frame: carried)
        let peer = try XCTUnwrap(engine.findNode(for: fixture.target, in: fixture.workspace)?.frameAnimation)
        let another = CGPoint(x: centre.x, y: centre.y - fixture.targetFrame.height / 8)
        let nextTouch = fixture.touch(at: another)
        let lastFrame = fixture.expectedFloatingFrame(at: nextTouch)
        let beforeTick = FrameApplyTrace.shared.dump()
        fixture.send(fixture.event(at: nextTouch))
        XCTAssertEqual(FrameApplyTrace.shared.dump(), beforeTick)
        let sample = fixture.controller.animationClock.now() + peer.animation.config.duration / 2
        handler.tickDwindleAnimation(targetTime: sample, displayId: fixture.monitor.displayId)
        let presented = try XCTUnwrap(engine.presentedFrame(for: fixture.target, in: fixture.workspace, at: sample))
        XCTAssertGreaterThan(presented.midX, fixture.startFrame.midX)
        XCTAssertLessThan(presented.midX, fixture.targetFrame.midX)
        let scale = refresh.buildMonitorSnapshot(for: fixture.monitor).scale
        assertFrameSubmission(fixture.target, frame: presented.roundedToPhysicalPixels(scale: scale))
        assertFrameSubmission(fixture.moved, frame: lastFrame)
        fixture.send(fixture.event(at: nextTouch, phase: .ended, sample: 3))
        try executePendingRelayout(refresh)
        let settled = try XCTUnwrap(engine.findNode(for: fixture.moved, in: fixture.workspace)?.frameAnimation)
        XCTAssertEqual(settled.fromFrame, fixture.startFrame.offsetBy(
            dx: another.x - fixture.startFrame.midX, dy: another.y - fixture.startFrame.midY
        ))
        XCTAssertEqual(settled.fromFrame.roundedToPhysicalPixels(scale: scale), lastFrame)
        XCTAssertEqual(settled.toFrame, fixture.targetFrame)
        let end = fixture.controller.animationClock.now() + settled.animation.config.duration
        handler.tickDwindleAnimation(targetTime: end, displayId: fixture.monitor.displayId)
        XCTAssertEqual(engine.presentedFrame(for: fixture.moved, in: fixture.workspace, at: end), fixture.targetFrame)
        assertFrameSubmission(fixture.moved, frame: fixture.targetFrame)
    }

    func testLiveDwindleLiftAppliesTheFinalVirtualPositionWhenMoveSpeedChanges() throws {
        let fixture = try liveDwindleFixture()
        let speedAtLift = GestureSettings.windowGestureSensitivityRange.upperBound
        let touch = Fixture.touch(
            at: fixture.targetFrame.center, from: fixture.startFrame.center, start: fixture.startTouch,
            display: fixture.monitor.frame, speed: CGFloat(speedAtLift)
        )
        fixture.begin()
        fixture.send(fixture.event(at: touch))
        XCTAssertTrue(fixture.handler.state.isMoving)
        XCTAssertEqual(fixture.order(), [[fixture.moved], [fixture.target]])
        fixture.controller.settings.gestures.windowMoveSensitivity = speedAtLift
        fixture.send(fixture.event(at: touch, phase: .ended))
        XCTAssertEqual(fixture.order(), [[fixture.target], [fixture.moved]])
        XCTAssertNil(fixture.base.dwindle.liveMoveToken)
        XCTAssertTrue(fixture.controller.dwindleLayoutHandler.stepLayoutHistory(.undo, in: fixture.workspace))
        XCTAssertEqual(fixture.order(), [[fixture.moved], [fixture.target]])
    }

    func testLiveDwindleReleaseInAGapKeepsTheLastAcceptedSwap() throws {
        let fixture = try liveDwindleFixture()
        let gap = CGPoint(x: (fixture.startFrame.maxX + fixture.targetFrame.minX) / 2, y: fixture.startFrame.midY)
        XCTAssertLessThan(fixture.startFrame.maxX, gap.x)
        XCTAssertLessThan(gap.x, fixture.targetFrame.minX)
        fixture.begin()
        fixture.move()
        let swapped = [[fixture.target], [fixture.moved]]
        XCTAssertEqual(fixture.order(), swapped)
        try executePendingRelayout(fixture.controller.layoutRefreshController)
        let touch = fixture.touch(at: gap)
        let sequence = fixture.base.manager.worldSeq
        fixture.send(fixture.event(at: touch))
        XCTAssertEqual(fixture.order(), swapped)
        XCTAssertEqual(fixture.base.manager.worldSeq, sequence)
        XCTAssertFalse(fixture.base.dwindle.liveMoveHoldsTarget(at: gap))
        XCTAssertTrue(fixture.handler.state.gestureOwnsWindowInteraction)
        fixture.send(fixture.event(at: touch, phase: .ended))
        XCTAssertEqual(fixture.order(), swapped)
        XCTAssertNil(fixture.base.dwindle.liveMoveToken)
        XCTAssertTrue(fixture.controller.dwindleLayoutHandler.stepLayoutHistory(.undo, in: fixture.workspace))
        XCTAssertEqual(fixture.order(), [[fixture.moved], [fixture.target]])
    }

    func testLiveDwindleSingleTileFollowsAndReturnsWithoutAnUndoEntry() throws {
        let fixture = try liveDwindleFixture(windows: 1)
        let touch = fixture.slideWithinStartingWindow(1 / 4)
        fixture.begin()
        fixture.send(fixture.event(at: touch))
        XCTAssertTrue(fixture.handler.state.gestureOwnsWindowInteraction)
        XCTAssertEqual(try fixture.projection().frameChanges.map(\.frame), [fixture.expectedFloatingFrame(at: touch)])
        fixture.send(fixture.event(at: touch, phase: .ended, sample: 3))
        XCTAssertEqual(try fixture.projection().frameChanges.map(\.frame), [fixture.startFrame])
        XCTAssertNil(fixture.base.dwindle.findNode(for: fixture.moved, in: fixture.workspace)?.frameAnimation)
        XCTAssertFalse(fixture.controller.dwindleLayoutHandler.stepLayoutHistory(.undo, in: fixture.workspace))
    }

    func testLiveDwindleRetiringTheCarriedGroupMemberRestoresTheSurvivorsWithoutHistory() throws {
        let fixture = try liveDwindleFixture(grouped: true)
        fixture.begin()
        fixture.move()
        let sibling = fixture.tokens[2]
        XCTAssertEqual(fixture.order(), [[fixture.target], [fixture.moved, sibling]])
        let entry = try XCTUnwrap(fixture.base.manager.entry(for: fixture.moved))
        fixture.controller.axEventHandler.retireManagedWindow(entry, reason: .authoritativeRescan)
        XCTAssertNil(fixture.base.manager.entry(for: fixture.moved))
        XCTAssertFalse(fixture.handler.state.gestureOwnsWindowInteraction)
        XCTAssertNil(fixture.base.dwindle.liveMoveToken)
        _ = try fixture.projection()
        XCTAssertEqual(fixture.order(), [[sibling], [fixture.target]])
        XCTAssertFalse(fixture.controller.dwindleLayoutHandler.stepLayoutHistory(.undo, in: fixture.workspace))
    }

    func testLiveDwindleCancelsOnAnotherWorkspaceOrLayoutAndLeavesNoUndoStep() throws {
        for changesWorkspace in [true, false] {
            let fixture = try liveDwindleFixture()
            let before = fixture.order()
            fixture.begin()
            fixture.move()
            XCTAssertEqual(fixture.order(), before.reversed())
            if changesWorkspace {
                fixture.controller.settings.workspaces.defaultLayoutType = .dwindle
                let other = try XCTUnwrap(fixture.base.manager.createDynamicWorkspace(
                    named: "2", on: fixture.monitor.id
                ))
                XCTAssertEqual(fixture.controller.settings.workspaces.layoutType(for: other.name), .dwindle)
                XCTAssertTrue(fixture.base.manager.setActiveWorkspace(other.id, on: fixture.monitor.id))
            } else {
                let settings = fixture.controller.settings.workspaces
                let workspace = try XCTUnwrap(fixture.base.manager.descriptor(for: fixture.workspace))
                let index = try XCTUnwrap(settings.configurations.firstIndex { $0.name == workspace.name })
                settings.configurations[index].layoutType = .niri
            }
            fixture.send(fixture.event(at: fixture.startTouch))
            XCTAssertEqual(fixture.order(), before)
            XCTAssertNil(fixture.base.dwindle.liveMoveToken)
            XCTAssertFalse(fixture.handler.state.gestureOwnsWindowInteraction)
            XCTAssertFalse(fixture.controller.dwindleLayoutHandler.stepLayoutHistory(.undo, in: fixture.workspace))
        }
    }

    func testLiveDwindleSwitchingTheShownGroupMemberCancelsOnMotionOrLift() throws {
        for lifts in [false, true] {
            let fixture = try liveDwindleFixture(grouped: true)
            let engine = fixture.base.dwindle
            let before = fixture.order()
            fixture.begin()
            fixture.move()
            XCTAssertEqual(fixture.order(), before.reversed())
            fixture.base.manager.withEngineMutationScope(in: fixture.workspace) {
                XCTAssertTrue(engine.activateWindow(fixture.tokens[2], in: fixture.workspace))
            }
            if lifts {
                fixture.release()
            } else {
                fixture.send(fixture.event(at: fixture.startTouch))
            }
            XCTAssertEqual(fixture.order(), before)
            XCTAssertNil(engine.liveMoveToken)
            XCTAssertFalse(fixture.handler.state.gestureOwnsWindowInteraction)
            XCTAssertFalse(fixture.controller.dwindleLayoutHandler.stepLayoutHistory(.undo, in: fixture.workspace))
        }
    }

    func testLiveDwindleDisableAndInputReplacementUndoProvisionalPlacement() throws {
        for disable in [true, false] {
            let fixture = try liveDwindleFixture()
            let before = fixture.order()
            fixture.begin()
            fixture.move()
            XCTAssertEqual(fixture.order(), before.reversed())
            if disable {
                fixture.controller.isEnabled = false
                fixture.send(fixture.event(at: fixture.startTouch))
            } else {
                fixture.handler.resetForMultitouchSourceReplacement()
            }
            XCTAssertEqual(fixture.order(), before)
            XCTAssertNil(fixture.base.dwindle.liveMoveToken)
            XCTAssertFalse(fixture.handler.state.gestureOwnsWindowInteraction)
            XCTAssertFalse(fixture.controller.dwindleLayoutHandler.stepLayoutHistory(.undo, in: fixture.workspace))
        }
    }

    func testLiveDwindleExactReturnAndMultipleSwapHistory() throws {
        for returnsHome in [false, true] {
            let fixture = try liveDwindleFixture(windows: 3)
            let initial = fixture.tokens.map { [$0] }
            fixture.begin()
            fixture.move()
            XCTAssertEqual(fixture.order(), [[fixture.target], [fixture.moved], [fixture.tokens[2]]])
            _ = try fixture.projection()
            let next = returnsHome ? fixture.startFrame.center : try XCTUnwrap(fixture.initialFrames[fixture.tokens[2]])
                .center
            let touch = fixture.touch(at: next)
            fixture.send(fixture.event(at: touch))
            let expected = returnsHome ? initial : [[fixture.target], [fixture.tokens[2]], [fixture.moved]]
            XCTAssertEqual(fixture.order(), expected)
            fixture.send(fixture.event(at: touch, phase: .ended, sample: 3))
            XCTAssertEqual(fixture.order(), expected)
            let handler = fixture.controller.dwindleLayoutHandler
            if returnsHome {
                XCTAssertFalse(handler.stepLayoutHistory(.undo, in: fixture.workspace))
            } else {
                XCTAssertTrue(handler.stepLayoutHistory(.undo, in: fixture.workspace))
                XCTAssertEqual(fixture.order(), initial)
                XCTAssertFalse(handler.stepLayoutHistory(.undo, in: fixture.workspace))
                XCTAssertTrue(handler.stepLayoutHistory(.redo, in: fixture.workspace))
                XCTAssertEqual(fixture.order(), expected)
            }
        }
    }
}
