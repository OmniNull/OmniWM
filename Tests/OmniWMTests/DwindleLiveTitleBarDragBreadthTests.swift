// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

extension DwindleLiveTitleBarDragTests {
    func testVerticalNativeGroupedSwapReleasesOrCancelsWithExactHistory() throws {
        for cancels in [false, true] {
            let fixture = try makeFixture(horizontal: false)
            fixture.assertLayout(swapped: false)
            let target = try XCTUnwrap(fixture.expectedFrames(swapped: false)[fixture.neighbor]).center
            try fixture.begin()
            XCTAssertTrue(fixture.handler.isInteractiveGestureActive)
            fixture.move(to: target)
            fixture.assertLayout(swapped: true)
            assertRepeatedNativePoint(target, fixture)
            if cancels {
                try fixture.cancel(at: target)
                fixture.assertLayout(swapped: false)
                fixture.assertHistory(undo: 0, redo: 0)
            } else {
                try fixture.release(at: target, swapped: true)
                fixture.assertLayout(swapped: true)
                fixture.assertHistory(undo: 1, redo: 0)
                fixture.command(.sizing(.undo))
                fixture.assertLayout(swapped: false)
                fixture.assertHistory(undo: 0, redo: 1)
                fixture.command(.sizing(.redo))
                fixture.assertLayout(swapped: true)
                fixture.assertHistory(undo: 1, redo: 0)
            }
            XCTAssertNil(fixture.engine.liveMoveWorkspaceId)
            XCTAssertNil(fixture.engine.interactiveMove)
        }
    }

    func testNativeGroupedDirectionalAndWorkspaceEdgeInsertionStayStableUntilCancel() throws {
        for workspaceEdge in [false, true] {
            let fixture = try makeFixture()
            let area = fixture.controller.insetWorkingFrame(for: fixture.monitor)
            let neighbor = try XCTUnwrap(fixture.expectedFrames(swapped: false)[fixture.neighbor])
            let point = workspaceEdge
                ? CGPoint(x: area.midX, y: area.maxY - FrameTolerance.screenMatch)
                : CGPoint(x: neighbor.midX, y: neighbor.maxY - neighbor.height / 8)
            if workspaceEdge {
                XCTAssertEqual(fixture.engine.workspaceEdgeDirection(at: point, in: area, from: nil), .up)
            } else {
                XCTAssertEqual(WindowMoveGeometry.insertionDirection(at: point, in: neighbor), .up)
                XCTAssertNil(fixture.engine.workspaceEdgeDirection(at: point, in: area, from: nil))
            }
            let group = try XCTUnwrap(fixture.engine.tile(containing: fixture.dragged, in: fixture.workspaceId))
            try fixture.begin()
            fixture.move(to: point)
            XCTAssertEqual(fixture.order(), [[fixture.neighbor], [fixture.tokens[0], fixture.dragged]])
            XCTAssertEqual(fixture.engine.root(for: fixture.workspaceId)?.splitOrientation, .vertical)
            XCTAssertEqual(fixture.engine.root(for: fixture.workspaceId)?.splitRatio, 1)
            let expected = breadthFrames(fixture, raw: [
                fixture.neighbor: CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2),
                fixture.dragged: CGRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2)
            ])
            XCTAssertEqual(fixture.engine.currentFrames(in: fixture.workspaceId), expected)
            XCTAssertTrue(fixture.engine.tile(containing: fixture.dragged, in: fixture.workspaceId) === group)
            XCTAssertEqual(group.activeToken, fixture.dragged)
            assertRepeatedNativePoint(point, fixture)
            fixture.assertHistory(undo: 0, redo: 0)
            try fixture.cancel(at: point)
            fixture.assertLayout(swapped: false)
            fixture.assertHistory(undo: 0, redo: 0)
        }
    }

    func testNativeGroupedSplitBoundaryInsertionKeepsTheAcceptedDividerPoint() throws {
        let fixture = try makeFixture()
        let extra = WindowToken(pid: fixture.dragged.pid, windowId: 4)
        _ = WindowAdmissionTestSupport.track(extra, in: fixture.workspaceId, controller: fixture.controller)
        fixture.manager.setCachedConstraints(.unconstrained, for: extra)
        fixture.manager.withEngineMutationScope(in: fixture.workspaceId) {
            fixture.engine.setSelectedNode(
                fixture.engine.findNode(for: fixture.neighbor, in: fixture.workspaceId),
                in: fixture.workspaceId
            )
            _ = fixture.engine.setPreselection(.up, in: fixture.workspaceId)
            _ = fixture.engine.addWindow(token: extra, to: fixture.workspaceId, activeWindowFrame: nil)
        }
        fixture.completeLayout()
        fixture.focus()
        let area = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        let point = CGPoint(x: area.minX + area.width * 3 / 4, y: area.midY)
        let split = try XCTUnwrap(fixture.engine.root(for: fixture.workspaceId)?.secondChild())
        guard case let .splitBoundary(id, _) = fixture.engine.splitBoundaryMoveTarget(
            at: point, for: fixture.dragged, in: fixture.workspaceId, time: fixture.controller.animationClock.now()
        ) else { return XCTFail("Expected the declared right subtree divider") }
        XCTAssertEqual(id, split.id)
        let group = try XCTUnwrap(fixture.engine.tile(containing: fixture.dragged, in: fixture.workspaceId))
        try fixture.begin()
        fixture.move(to: point)
        XCTAssertEqual(fixture.order(), [[fixture.neighbor], [fixture.tokens[0], fixture.dragged], [extra]])
        let root = try XCTUnwrap(fixture.engine.root(for: fixture.workspaceId))
        XCTAssertEqual(root.splitOrientation, .vertical)
        XCTAssertEqual(root.secondChild()?.splitOrientation, .vertical)
        XCTAssertEqual(root.splitRatio, 1)
        XCTAssertEqual(root.secondChild()?.splitRatio, 1)
        let expected = breadthFrames(fixture, raw: [
            fixture.neighbor: CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2),
            fixture.dragged: CGRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 4),
            extra: CGRect(
                x: area.minX,
                y: area.minY + area.height * 3 / 4,
                width: area.width,
                height: area.height / 4
            )
        ])
        XCTAssertEqual(fixture.engine.currentFrames(in: fixture.workspaceId), expected)
        XCTAssertTrue(fixture.engine.tile(containing: fixture.dragged, in: fixture.workspaceId) === group)
        assertRepeatedNativePoint(point, fixture)
        XCTAssertEqual(fixture.engine.currentFrames(in: fixture.workspaceId), expected)
        try fixture.cancel(at: point)
        XCTAssertEqual(fixture.order(), [[fixture.tokens[0], fixture.dragged], [fixture.neighbor], [extra]])
        XCTAssertEqual(fixture.engine.root(for: fixture.workspaceId)?.secondChild()?.splitOrientation, .vertical)
        let restored = breadthFrames(fixture, raw: [
            fixture.dragged: CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height),
            fixture.neighbor: CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height / 2),
            extra: CGRect(x: area.midX, y: area.midY, width: area.width / 2, height: area.height / 2)
        ])
        XCTAssertEqual(fixture.engine.currentFrames(in: fixture.workspaceId), restored)
        fixture.assertHistory(undo: 0, redo: 0)
        XCTAssertNil(fixture.engine.liveMoveWorkspaceId)
    }

    func testNativeRepeatedPointPreservesMidpointPresentedAnimation() throws {
        let fixture = try makeFixture()
        let original = fixture.expectedFrames(swapped: false)
        let swapped = fixture.expectedFrames(swapped: true)
        let point = try XCTUnwrap(original[fixture.neighbor]).center
        try fixture.begin()
        fixture.move(to: point)
        let node = try XCTUnwrap(fixture.engine.findNode(for: fixture.neighbor, in: fixture.workspaceId))
        let from = try XCTUnwrap(original[fixture.neighbor])
        let to = try XCTUnwrap(swapped[fixture.neighbor])
        let config = fixture.engine.windowMovementAnimationConfig
        let sample = fixture.controller.animationClock.now()
        let start = sample - config.duration / 2
        let progress = CGFloat(config.value(at: (sample - start) / config.duration))
        let presented = CGRect(
            x: from.minX + (to.minX - from.minX) * progress,
            y: from.minY + (to.minY - from.minY) * progress,
            width: from.width + (to.width - from.width) * progress,
            height: from.height + (to.height - from.height) * progress
        )
        node.animateFrom(oldFrame: from, newFrame: to, startTime: start, config: config, animated: true)
        XCTAssertEqual(node.presentedFrame(at: sample), presented)
        XCTAssertTrue(node.hasActiveAnimations(at: sample))

        assertRepeatedNativePoint(point, fixture)

        XCTAssertEqual(node.presentedFrame(at: sample), presented)
        XCTAssertTrue(node.hasActiveAnimations(at: sample))
        fixture.assertLayout(swapped: true)
        fixture.assertHistory(undo: 0, redo: 0)
        try fixture.cancel(at: point)
        fixture.assertLayout(swapped: false)
    }

    func testNativeSourceOrTargetRetirementCannotResurrectAWindowOrRecordHistory() throws {
        for removesSource in [false, true] {
            let fixture = try makeFixture()
            let point = try XCTUnwrap(fixture.expectedFrames(swapped: false)[fixture.neighbor]).center
            try fixture.begin()
            fixture.move(to: point)
            fixture.assertLayout(swapped: true)
            let removed = removesSource ? fixture.dragged : fixture.neighbor
            fixture.controller.axEventHandler.retireManagedWindowFromAuthoritativeRescan(
                try XCTUnwrap(fixture.manager.entry(for: removed))
            )
            fixture.handler.cancelActiveMouseInteraction()
            fixture.completeLayout()
            XCTAssertNil(fixture.manager.entry(for: removed))
            XCTAssertNil(fixture.engine.findNode(for: removed, in: fixture.workspaceId))
            let expectedMembers = fixture.tokens.filter { $0 != removed }
            XCTAssertEqual(Set(fixture.manager.entries(in: fixture.workspaceId).map(\.token)), Set(expectedMembers))
            XCTAssertEqual(
                fixture.order(),
                removesSource
                    ? [[fixture.tokens[0]], [fixture.neighbor]] : [[fixture.tokens[0], fixture.dragged]]
            )
            fixture.assertHistory(undo: 0, redo: 0)
            XCTAssertNil(fixture.engine.liveMoveWorkspaceId)
            XCTAssertNil(fixture.engine.interactiveMove)
            XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
        }
    }

    func testNativeEdgeResizeNeverAdmitsLiveMovementAndExactReturnAddsNoHistory() throws {
        let fixture = try makeFixture()
        let start = try XCTUnwrap(fixture.expectedFrames(swapped: false)[fixture.dragged])
        let point = CGPoint(x: start.maxX, y: start.midY)
        let delta = fixture.controller.insetWorkingFrame(for: fixture.monitor).width / 8
        fixture.report(start)
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        XCTAssertFalse(fixture.handler.dispatchMouseDown(
            at: point, modifiers: [], windowIdUnderPointer: fixture.dragged.windowId
        ))
        fixture.handler.dispatchMouseDragged(at: CGPoint(x: point.x + delta, y: point.y))
        fixture.report(CGRect(x: start.minX, y: start.minY, width: start.width + delta, height: start.height))
        let entry = try XCTUnwrap(fixture.manager.entry(for: fixture.dragged))
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: entry))
        XCTAssertNil(fixture.engine.liveMoveWorkspaceId)
        XCTAssertNil(fixture.engine.liveMoveToken)
        XCTAssertFalse(fixture.handler.state.nativeTitleBarDrag?.canStartLiveDwindleDrag == true)
        XCTAssertFalse(fixture.handler.state.nativeTitleBarDrag?.dwindleLiveDrag == true)
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.dwindleResizeWorkspaceId, fixture.workspaceId)
        XCTAssertNotNil(fixture.engine.interactiveResize)
        XCTAssertEqual(fixture.order(), [[fixture.tokens[0], fixture.dragged], [fixture.neighbor]])
        fixture.report(start)
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: entry))
        try fixture.release(at: point, swapped: false)
        fixture.assertLayout(swapped: false)
        fixture.assertHistory(undo: 0, redo: 0)
        XCTAssertNil(fixture.engine.interactiveResize)
    }

    private func assertRepeatedNativePoint(_ point: CGPoint, _ fixture: Fixture) {
        let sequence = fixture.manager.worldSeq
        fixture.handler.dispatchMouseDragged(at: point)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
        XCTAssertTrue(fixture.engine.liveMoveHoldsTarget(at: point))
    }

    private func breadthFrames(_ fixture: Fixture, raw: [WindowToken: CGRect]) -> [WindowToken: CGRect] {
        let area = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        var frames: [WindowToken: CGRect] = [:]
        for (token, rawFrame) in raw {
            var frame = DwindleGapCalculator.applyGaps(
                nodeRect: rawFrame, tilingArea: area, settings: fixture.engine.settings
            )
            if token == fixture.dragged {
                let rail = min(fixture.controller.tabRailStyle.reservedWidth, frame.width)
                frame.origin.x += rail
                frame.size.width -= rail
            }
            frames[token] = frame
        }
        return frames
    }
}
