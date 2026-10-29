// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriNaturalEdgeResizeTests: NiriInteractionTestCase {
    @MainActor
    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let tokens: [WindowToken]
        var orientation: Monitor.Orientation = .horizontal

        var handler: MouseEventHandler {
            controller.mouseEventHandler
        }

        var manager: WorkspaceManager {
            controller.workspaceManager
        }

        var engine: NiriLayoutEngine {
            controller.niriEngine!
        }

        var phase: MouseInputState.NativeTitleBarDragPhase? {
            handler.state.nativeTitleBarDrag?.phase
        }

        var widest: CGFloat {
            controller.insetWorkingFrame(for: monitor).width - 2 * controller.innerGap(for: monitor)
        }

        func node(_ token: WindowToken) throws -> NiriWindow {
            try XCTUnwrap(engine.findNode(for: token, in: workspaceId))
        }

        func column(_ token: WindowToken) throws -> NiriContainer {
            try XCTUnwrap(engine.findColumn(containing: node(token), in: workspaceId))
        }

        func frames() -> [WindowToken: CGRect] {
            let gap = controller.innerGap(for: monitor)
            return engine.calculateLayout(
                state: manager.niriViewportState(for: workspaceId),
                workspaceId: workspaceId,
                monitorFrame: controller.insetWorkingFrame(for: monitor),
                gaps: (horizontal: gap, vertical: gap),
                orientation: orientation
            )
        }

        func frame(_ token: WindowToken) throws -> CGRect {
            try XCTUnwrap(frames()[token])
        }

        func settledFrame(_ token: WindowToken) throws -> CGRect {
            try frame(token, after: 10)
        }

        func frame(_ token: WindowToken, after seconds: TimeInterval) throws -> CGRect {
            let gap = controller.innerGap(for: monitor)
            let later = (engine.animationClock?.now() ?? CACurrentMediaTime()) + seconds
            return try XCTUnwrap(engine.calculateLayoutWithVisibility(
                state: manager.niriViewportState(for: workspaceId),
                workspaceId: workspaceId,
                monitorFrame: controller.insetWorkingFrame(for: monitor),
                gaps: (horizontal: gap, vertical: gap),
                orientation: orientation,
                animationTime: later
            ).frames[token])
        }

        func confirmLayout() {
            for (token, frame) in frames() {
                controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame)
            }
        }

        func beginDrag(_ token: WindowToken) throws {
            handler.retireNativeTitleBarDragAtInputBoundary()
            applyPendingFrames()
            handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            let start = try frame(token)
            handler.nativeWindowFrameProvider = { _ in start }
            XCTAssertFalse(handler.dispatchMouseDown(
                at: start.center,
                modifiers: [],
                windowIdUnderPointer: token.windowId
            ))
            handler.dispatchMouseDragged(at: CGPoint(x: start.center.x + 5, y: start.center.y))
            XCTAssertEqual(phase, .dragging)
        }

        func drag(_ token: WindowToken, to observed: CGRect) {
            handler.nativeWindowFrameProvider = { _ in observed }
            controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
        }

        func release(at observed: CGRect) {
            handler.nativeWindowFrameProvider = { _ in observed }
            handler.dispatchMouseUp(at: observed.center)
        }

        func moveByTitleBar(
            _ token: WindowToken,
            from frame: CGRect,
            by dy: CGFloat,
            releasingAt cursor: CGPoint
        ) throws {
            try beginDrag(token)
            let moved = frame.offsetBy(dx: 0, dy: dy)
            drag(token, to: moved)
            XCTAssertTrue(handler.isLiveColumnDragActive)
            handler.dispatchMouseDragged(at: cursor)
            handler.nativeWindowFrameProvider = { _ in moved }
            handler.dispatchMouseUp(at: cursor)
            _ = frames()
            applyPendingFrames()
        }

        func resize(_ token: WindowToken, to observed: CGRect) throws {
            try beginDrag(token)
            drag(token, to: observed)
            release(at: observed)
            applyPendingFrames()
        }

        func applyPendingFrames() {
            controller.axManager.cancelPendingFrameJobs(
                tokens.map { (pid: $0.pid, windowId: $0.windowId) },
                reason: "test-frames-applied"
            )
            confirmLayout()
        }

        @discardableResult
        func doubleClick(at point: CGPoint) -> Bool {
            handler.retireNativeTitleBarDragAtInputBoundary()
            let taken = handler.dispatchAuthoritativeTap(
                type: .leftMouseDown, location: point, modifiers: [], buttonNumber: 0, scrollPayload: nil, clickCount: 2
            )
            _ = handler.dispatchAuthoritativeTap(
                type: .leftMouseUp, location: point, modifiers: [], buttonNumber: 0, scrollPayload: nil
            )
            _ = frames()
            return taken
        }
    }

    func testDuringAnEdgeDragNothingElseMoves() throws {
        let fixture = try makeFixture(pid: 871_001)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let frames = fixture.frames()
        let resized = fixture.tokens[1]
        try fixture.beginDrag(resized)

        for delta: CGFloat in [60, 140, 90] {
            fixture.drag(resized, to: grown(try XCTUnwrap(frames[resized]), right: delta))

            XCTAssertEqual(fixture.phase, .dragging)
            XCTAssertEqual(fixture.frames(), frames, "\(delta)")
            XCTAssertNil(fixture.engine.interactiveResize)
        }
    }

    func testReleasingARightEdgeDragWidensTheColumnAndMovesTheNeighbour() throws {
        let fixture = try makeFixture(pid: 871_002)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (resized, right) = (fixture.tokens[1], fixture.tokens[2])
        let start = try fixture.frame(resized)
        let rightStart = try fixture.frame(right)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, right: 100))

        fixture.release(at: grown(start, right: 100))

        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertNil(fixture.engine.interactiveResize)
        XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
        let frame = try fixture.frame(resized)
        XCTAssertEqual(frame.minX, start.minX, accuracy: 1)
        XCTAssertEqual(frame.width, start.width + 100, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(right).minX, rightStart.minX + 100, accuracy: 1)
    }

    func testOnReleaseTheNeighboursSlideAndTheDraggedWindowDoesnt() throws {
        let fixture = try makeFixture(pid: 871_016)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (resized, right) = (fixture.tokens[1], fixture.tokens[2])
        let start = try fixture.frame(resized)
        let rightStart = try fixture.frame(right)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, right: 100))

        fixture.release(at: grown(start, right: 100))

        XCTAssertTrue(try fixture.node(right).hasMoveAnimationsRunning)
        XCTAssertEqual(try fixture.frame(right).minX, rightStart.minX, accuracy: 1)
        XCTAssertFalse(try fixture.node(resized).hasMoveAnimationsRunning)
        XCTAssertEqual(try fixture.frame(resized).width, start.width + 100, accuracy: 1)
    }

    func testAStackMateSlidesItsNearEdgeAndKeepsItsFarEdgePut() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_017)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, lower) = try upperAndLower(fixture)
        let upperStart = try fixture.frame(upper)
        let lowerStart = try fixture.frame(lower)
        try fixture.beginDrag(lower)
        fixture.drag(lower, to: grown(lowerStart, top: 100))

        fixture.release(at: grown(lowerStart, top: 100))

        XCTAssertTrue(try fixture.node(upper).hasMoveAnimationsRunning)
        XCTAssertFalse(try fixture.node(lower).hasMoveAnimationsRunning)
        XCTAssertEqual(try fixture.frame(upper), upperStart)
        let midway = try fixture.frame(upper, after: 0.08)
        XCTAssertEqual(midway.maxY, upperStart.maxY, accuracy: 1)
        XCTAssertLessThan(midway.height, upperStart.height - 1)
        XCTAssertGreaterThan(midway.height, upperStart.height - 99)
        let settled = try fixture.settledFrame(upper)
        XCTAssertEqual(settled.maxY, upperStart.maxY, accuracy: 1)
        XCTAssertEqual(settled.height, upperStart.height - 100, accuracy: 1)
    }

    func testAStackMateDoesntSlideSideways() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_019)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, lower) = try upperAndLower(fixture)
        let upperStart = try fixture.frame(upper)
        let lowerStart = try fixture.frame(lower)
        try fixture.beginDrag(lower)
        fixture.drag(lower, to: grown(lowerStart, left: 80))

        fixture.release(at: grown(lowerStart, left: 80))

        let frame = try fixture.frame(upper)
        XCTAssertEqual(frame.maxX, upperStart.maxX, accuracy: 1)
        XCTAssertEqual(frame.width, upperStart.width + 80, accuracy: 1)
    }

    func testOnAVerticalStripAKeptEdgeResizeDoesntSlide() throws {
        let fixture = try makeFixture(portrait: true, pid: 871_020)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        fixture.controller.settings.gestures.adoptNativeResize = true
        XCTAssertEqual(fixture.handler.liveColumnContext(for: fixture.workspaceId)?.orientation, .vertical)
        let resized = fixture.tokens[1]
        let start = try fixture.frame(resized)
        let observed = grown(start, bottom: 100)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: observed)

        fixture.release(at: observed)

        for token in fixture.tokens {
            XCTAssertFalse(try fixture.node(token).hasMoveAnimationsRunning)
        }
    }

    func testWithoutNaturalWindowDragNothingSlides() throws {
        let fixture = try makeFixture(pid: 871_018)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        fixture.controller.settings.niri.naturalWindowDrag = false
        fixture.controller.settings.gestures.adoptNativeResize = true
        let (resized, right) = (fixture.tokens[1], fixture.tokens[2])
        let start = try fixture.frame(resized)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, right: 100))

        fixture.release(at: grown(start, right: 100))

        XCTAssertFalse(try fixture.node(right).hasMoveAnimationsRunning)
    }

    func testReleasingALeftEdgeDragKeepsTheRightSidePut() throws {
        let fixture = try makeFixture(pid: 871_003)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (left, resized) = (fixture.tokens[0], fixture.tokens[1])
        let start = try fixture.frame(resized)
        let leftStart = try fixture.frame(left)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, left: 80))

        fixture.release(at: grown(start, left: 80))

        let frame = try fixture.frame(resized)
        XCTAssertEqual(frame.maxX, start.maxX, accuracy: 1)
        XCTAssertEqual(frame.width, start.width + 80, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(left).maxX, leftStart.maxX - 80, accuracy: 1)
    }

    func testReleasingDoesntMoveTheView() throws {
        for (pid, edges) in [
            (pid_t(871_004), (left: CGFloat(0), right: CGFloat(250))),
            (871_005, (left: 250, right: 0))
        ] {
            let fixture = try makeFixture(pid: pid)
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let resized = fixture.tokens[1]
            let start = try fixture.frame(resized)
            let viewport = fixture.manager.niriViewportState(for: fixture.workspaceId)
            let grownFrame = grown(start, left: edges.left, right: edges.right)
            try fixture.beginDrag(resized)
            fixture.drag(resized, to: grownFrame)

            fixture.release(at: grownFrame)

            let settled = fixture.manager.niriViewportState(for: fixture.workspaceId)
            XCTAssertEqual(settled.activeColumnIndex, viewport.activeColumnIndex, "\(edges)")
            if edges.left == 0 {
                XCTAssertEqual(settled.viewOffset, viewport.viewOffset, accuracy: 0.5, "\(edges)")
            }
            XCTAssertEqual(try fixture.frame(resized).minX, grownFrame.minX, accuracy: 1, "\(edges)")
            XCTAssertEqual(try fixture.frame(resized).maxX, grownFrame.maxX, accuracy: 1, "\(edges)")
        }
    }

    func testReleasingAStackedWindowsTopEdgeMakesTheOtherGiveWay() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_006)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, lower) = try upperAndLower(fixture)
        let upperStart = try fixture.frame(upper)
        let lowerStart = try fixture.frame(lower)
        try fixture.beginDrag(lower)
        fixture.drag(lower, to: grown(lowerStart, top: 100))

        fixture.release(at: grown(lowerStart, top: 100))

        XCTAssertEqual(try fixture.frame(lower).height, lowerStart.height + 100, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(upper).height, upperStart.height - 100, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(upper).maxY, upperStart.maxY, accuracy: 1)
    }

    func testReleasingAStackedWindowsBottomEdgeMakesTheOtherGiveWay() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_007)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, lower) = try upperAndLower(fixture)
        let upperStart = try fixture.frame(upper)
        let lowerStart = try fixture.frame(lower)
        try fixture.beginDrag(upper)
        fixture.drag(upper, to: grown(upperStart, bottom: 100))

        fixture.release(at: grown(upperStart, bottom: 60))

        XCTAssertEqual(try fixture.frame(upper).height, upperStart.height + 60, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(lower).height, lowerStart.height - 60, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(lower).minY, lowerStart.minY, accuracy: 1)
    }

    func testAStacksOuterEdgesSnapBack() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_027)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, lower) = try upperAndLower(fixture)
        let upperStart = try fixture.frame(upper)
        let lowerStart = try fixture.frame(lower)

        try fixture.resize(upper, to: grown(upperStart, top: -100))
        try fixture.resize(lower, to: grown(lowerStart, bottom: -100))

        XCTAssertEqual(try fixture.settledFrame(upper), upperStart)
        XCTAssertEqual(try fixture.settledFrame(lower), lowerStart)
        XCTAssertTrue(try fixture.node(upper).height.isAuto)
        XCTAssertTrue(try fixture.node(lower).height.isAuto)
    }

    func testAnOuterCornerOfAStackChangesOnlyTheWidth() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_028)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, lower) = try upperAndLower(fixture)
        let upperStart = try fixture.frame(upper)
        let lowerStart = try fixture.frame(lower)

        try fixture.resize(upper, to: grown(upperStart, right: 80, top: -100))

        let frame = try fixture.settledFrame(upper)
        XCTAssertEqual(frame.width, upperStart.width + 80, accuracy: 1)
        XCTAssertEqual(frame.height, upperStart.height, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(lower).height, lowerStart.height, accuracy: 1)
    }

    func testAnInnerCornerOfAStackChangesTheWidthAndTheHeight() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_033)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, lower) = try upperAndLower(fixture)
        let upperStart = try fixture.frame(upper)
        let lowerStart = try fixture.frame(lower)

        try fixture.resize(lower, to: grown(lowerStart, right: 80, top: 100))

        let frame = try fixture.settledFrame(lower)
        XCTAssertEqual(frame.width, lowerStart.width + 80, accuracy: 1)
        XCTAssertEqual(frame.height, lowerStart.height + 100, accuracy: 1)
        XCTAssertEqual(frame.minY, lowerStart.minY, accuracy: 1)
        let mate = try fixture.settledFrame(upper)
        XCTAssertEqual(mate.width, upperStart.width + 80, accuracy: 1)
        XCTAssertEqual(mate.height, upperStart.height - 100, accuracy: 1)
        XCTAssertEqual(mate.maxY, upperStart.maxY, accuracy: 1)
    }

    func testATabbedColumnsTopEdgeGoesBackToTheFullHeight() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_034)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (shown, right) = (fixture.tokens[0], fixture.tokens[2])
        try makeTabbed(fixture, showing: shown)
        let start = try fixture.frame(shown)
        let rightStart = try fixture.frame(right)

        try fixture.resize(shown, to: grown(start, top: -150))

        XCTAssertEqual(try fixture.settledFrame(shown), start)
        XCTAssertEqual(try fixture.settledFrame(right), rightStart)
        XCTAssertTrue(try fixture.node(shown).height.isAuto)
    }

    func testATabbedColumnsSideEdgeWidensEveryTab() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_035)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (shown, hidden, right) = (fixture.tokens[0], fixture.tokens[1], fixture.tokens[2])
        let column = try makeTabbed(fixture, showing: shown)
        let start = try fixture.frame(shown)
        let rightStart = try fixture.frame(right)
        let widthStart = column.cachedWidth

        try fixture.resize(shown, to: grown(start, right: 100))

        let widened = try fixture.settledFrame(shown)
        XCTAssertEqual(widened.width, start.width + 100, accuracy: 1)
        XCTAssertEqual(widened.height, start.height, accuracy: 1)
        XCTAssertEqual(column.cachedWidth, widthStart + 100, accuracy: 1)
        XCTAssertTrue(try fixture.column(hidden) === column)
        XCTAssertEqual(try fixture.settledFrame(right).minX, rightStart.minX + 100, accuracy: 1)
    }

    func testALoneWindowShortenedFromTheTopSitsAtTheBottom() throws {
        let fixture = try makeFixture(pid: 871_008)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)
        let shorter = grown(start, top: -150)
        try fixture.beginDrag(lone)
        fixture.drag(lone, to: shorter)

        fixture.release(at: shorter)

        XCTAssertEqual(try fixture.frame(lone).height, start.height - 150, accuracy: 1)
        XCTAssertEqual(try fixture.frame(lone).minY, start.minY, accuracy: 1)
        XCTAssertFalse(try fixture.node(lone).height.isAuto)
    }

    func testALoneWindowShortenedFromTheBottomSitsAtTheTop() throws {
        let fixture = try makeFixture(pid: 871_020)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)

        try fixture.resize(lone, to: grown(start, bottom: -150))

        let frame = try fixture.settledFrame(lone)
        XCTAssertEqual(frame.maxY, start.maxY, accuracy: 1)
        XCTAssertEqual(frame.minY, start.minY + 150, accuracy: 1)
    }

    func testTheEdgeAtTheColumnsEndSnapsBack() throws {
        let fixture = try makeFixture(pid: 871_021)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (atBottom, atTop) = (fixture.tokens[0], fixture.tokens[1])
        try fixture.resize(atBottom, to: grown(try fixture.frame(atBottom), top: -150))
        try fixture.resize(atTop, to: grown(try fixture.frame(atTop), bottom: -150))
        let bottomPlaced = try fixture.settledFrame(atBottom)
        let topPlaced = try fixture.settledFrame(atTop)

        try fixture.resize(atBottom, to: grown(bottomPlaced, bottom: -80))
        try fixture.resize(atTop, to: grown(topPlaced, top: -80))

        XCTAssertEqual(try fixture.settledFrame(atBottom), bottomPlaced)
        XCTAssertEqual(try fixture.settledFrame(atTop), topPlaced)
    }

    func testDraggingTheFreeEdgeToTheColumnsEndGivesTheFullHeight() throws {
        let fixture = try makeFixture(pid: 871_029)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)
        try fixture.resize(lone, to: grown(start, bottom: -150))

        try fixture.resize(lone, to: grown(try fixture.settledFrame(lone), bottom: 150))

        XCTAssertEqual(try fixture.settledFrame(lone), start)
        try fixture.resize(lone, to: grown(start, top: -100))
        let frame = try fixture.settledFrame(lone)
        XCTAssertEqual(frame.minY, start.minY, accuracy: 1)
        XCTAssertEqual(frame.height, start.height - 100, accuracy: 1)
    }

    func testDroppingALoneWindowInItsSpaceMovesItToThatEnd() throws {
        let fixture = try makeFixture(pid: 871_030)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)
        try fixture.resize(lone, to: grown(start, top: -300))
        let atBottom = try fixture.settledFrame(lone)

        try fixture.moveByTitleBar(
            lone,
            from: atBottom,
            by: 200,
            releasingAt: CGPoint(x: atBottom.midX, y: atBottom.maxY + 100)
        )

        XCTAssertTrue(try fixture.node(lone).hasMoveAnimationsRunning)
        let atTop = try fixture.settledFrame(lone)
        XCTAssertEqual(atTop.maxY, start.maxY, accuracy: 1)
        XCTAssertEqual(atTop.height, atBottom.height, accuracy: 1)
    }

    func testDroppingALoneWindowInTheSpaceBelowMovesItToTheBottom() throws {
        let fixture = try makeFixture(pid: 871_032)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)
        try fixture.resize(lone, to: grown(start, bottom: -300))
        let atTop = try fixture.settledFrame(lone)

        try fixture.moveByTitleBar(
            lone,
            from: atTop,
            by: -200,
            releasingAt: CGPoint(x: atTop.midX, y: atTop.minY - 100)
        )

        let atBottom = try fixture.settledFrame(lone)
        XCTAssertEqual(atBottom.minY, start.minY, accuracy: 1)
        XCTAssertEqual(atBottom.height, atTop.height, accuracy: 1)
    }

    func testReleasingItOutsideTheSpaceLeavesItWhereItWas() throws {
        let fixture = try makeFixture(pid: 871_031)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)
        try fixture.resize(lone, to: grown(start, top: -300))
        let atBottom = try fixture.settledFrame(lone)

        try fixture.moveByTitleBar(
            lone,
            from: atBottom,
            by: 80,
            releasingAt: CGPoint(x: atBottom.midX, y: atBottom.midY)
        )

        XCTAssertEqual(try fixture.settledFrame(lone).minY, atBottom.minY, accuracy: 1)
    }

    func testTheEndSurvivesARelayoutAndAScroll() throws {
        let fixture = try makeFixture(pid: 871_022)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)
        try fixture.resize(lone, to: grown(start, bottom: -150))
        let placed = try fixture.settledFrame(lone)

        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.jumpOffset(to: state.viewOffset + 40)
        }

        let frame = try fixture.settledFrame(lone)
        XCTAssertEqual(frame.minY, placed.minY, accuracy: 1)
        XCTAssertEqual(frame.height, placed.height, accuracy: 1)
    }

    func testADoubleClickRoundTripKeepsTheEnd() throws {
        let fixture = try makeFixture(pid: 871_023)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)
        try fixture.resize(lone, to: grown(start, bottom: -150))
        let placed = try fixture.settledFrame(lone)

        XCTAssertTrue(fixture.doubleClick(at: CGPoint(x: placed.midX, y: placed.maxY - 1)))
        XCTAssertEqual(try fixture.settledFrame(lone).height, start.height, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(lone).minY, start.minY, accuracy: 1)

        let full = try fixture.settledFrame(lone)
        XCTAssertTrue(fixture.doubleClick(at: CGPoint(x: full.midX, y: full.maxY - 1)))
        let restored = try fixture.settledFrame(lone)
        XCTAssertEqual(restored.minY, placed.minY, accuracy: 1)
        XCTAssertEqual(restored.height, placed.height, accuracy: 1)
    }

    func testAnotherHeightChangeForgetsTheEnd() throws {
        let fixture = try makeFixture(pid: 871_024)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)
        try fixture.resize(lone, to: grown(start, bottom: -150))

        try fixture.node(lone).height = .fixed(start.height - 200)

        XCTAssertEqual(try fixture.settledFrame(lone).minY, start.minY, accuracy: 1)
    }

    func testTheProjectedAndLiveStackPlacesAgreeWithTheLayout() throws {
        let fixture = try makeFixture(pid: 871_025)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)
        try fixture.resize(lone, to: grown(start, bottom: -150))
        let placed = try fixture.settledFrame(lone)
        let column = try fixture.column(lone)
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.workspaceId))

        let projected = fixture.engine.projectedGeometrySnapshot(
            in: fixture.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: .horizontal
        )
        let offset = try XCTUnwrap(projected.secondaryOffset(of: try fixture.node(lone), in: column))
        XCTAssertEqual(offset - context.gaps, placed.minY - start.minY, accuracy: 1)
        let span = try XCTUnwrap(fixture.engine.liveWindowSpans(in: column, context: context).first)
        XCTAssertEqual(span.minY, placed.minY, accuracy: 1)
    }

    func testATopRestAppliesOnlyToItsColumnAndHeight() throws {
        let fixture = try makeFixture(pid: 871_026)
        let window = try fixture.node(fixture.tokens[1])
        let column = try fixture.column(fixture.tokens[1])
        let other = try fixture.column(fixture.tokens[2])
        window.height = .fixed(300)

        window.rest(atTop: true, in: column)

        XCTAssertTrue(window.restsAtTop(of: column))
        XCTAssertFalse(window.restsAtTop(of: other))
        XCTAssertEqual(window.restingOffset(in: column, room: 80), 80)
        XCTAssertEqual(window.restingOffset(in: column, room: -10), 0)
        XCTAssertEqual(window.restingOffset(in: other, room: 80), 0)
        window.height = .fixed(320)
        XCTAssertFalse(window.restsAtTop(of: column))
    }

    func testTurningNaturalWindowDragOffForgetsTopRests() throws {
        let fixture = try makeFixture(pid: 871_091)
        let window = try fixture.node(fixture.tokens[1])
        let column = try fixture.column(fixture.tokens[1])
        window.height = .fixed(300)
        window.rest(atTop: true, in: column)
        XCTAssertTrue(window.restsAtTop(of: column))

        fixture.controller.settings.niri.naturalWindowDrag = false
        fixture.controller.applyNaturalWindowDragSettings()

        XCTAssertFalse(window.restsAtTop(of: column))
    }

    func testTheWidthStopsAtTheWidestColumn() throws {
        let fixture = try makeFixture(pid: 871_011)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let resized = fixture.tokens[1]
        let start = try fixture.frame(resized)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, right: 5000))

        fixture.release(at: grown(start, right: 5000))

        XCTAssertEqual(try fixture.frame(resized).width, fixture.widest, accuracy: 1)
        XCTAssertEqual(fixture.phase, .awaitingCorrection)
    }

    func testAnEdgeDragReleasedPastThePeekStopsAtIt() throws {
        let fixture = try makeFixture(pid: 871_190)
        fixture.controller.settings.niri.edgePeek = true
        fixture.controller.applyNaturalWindowDragSettings()
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let resized = fixture.tokens[1]
        let start = try fixture.frame(resized)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, right: 5000))

        fixture.release(at: grown(start, right: 5000))

        let gap = fixture.controller.innerGap(for: fixture.monitor)
        let cap = fixture.monitor.frame.width - 2 * ((fixture.monitor.frame.width * 0.03).rounded() + gap)
        XCTAssertEqual(try fixture.frame(resized).width, cap, accuracy: 1)
    }

    func testATitleBarDragStaysALiveColumnMove() throws {
        let fixture = try makeFixture(pid: 871_012)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let moved = fixture.tokens[1]
        let start = try fixture.frame(moved)
        try fixture.beginDrag(moved)

        fixture.drag(moved, to: start.offsetBy(dx: 60, dy: 0))

        XCTAssertTrue(fixture.handler.isLiveColumnDragActive)
        XCTAssertNil(fixture.engine.interactiveResize)
    }

    func testKeepNativeEdgeResizesAloneStillAdopts() throws {
        let fixture = try makeFixture(pid: 871_015)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        fixture.controller.settings.niri.naturalWindowDrag = false
        fixture.controller.settings.gestures.adoptNativeResize = true
        let resized = fixture.tokens[1]
        let start = try fixture.frame(resized)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, right: 100))

        fixture.release(at: grown(start, right: 100))

        XCTAssertEqual(try fixture.column(resized).cachedWidth, start.width + 100, accuracy: 1)
    }

    func testWithTheSettingOffAnEdgeDragIsntAdopted() throws {
        let fixture = try makeFixture(pid: 871_013)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        fixture.controller.settings.niri.naturalWindowDrag = false
        let (resized, right) = (fixture.tokens[1], fixture.tokens[2])
        let start = try fixture.frame(resized)
        let rightStart = try fixture.frame(right)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, right: 100))

        fixture.release(at: grown(start, right: 100))

        XCTAssertEqual(try fixture.frame(resized), start)
        XCTAssertEqual(try fixture.frame(right), rightStart)
    }

    func testOnlyACentredResizeCountsBothSides() {
        let start = CGRect(x: 100, y: 100, width: 400, height: 300)

        XCTAssertEqual(
            MouseEventHandler.nativeResizeEdges(
                from: start,
                to: grown(start, left: 50, right: 50),
                allowsCentred: true
            ),
            [.left, .right]
        )
        XCTAssertEqual(
            MouseEventHandler.nativeResizeEdges(
                from: start,
                to: grown(start, bottom: -40, top: -40),
                allowsCentred: true
            ),
            [.top, .bottom]
        )
        XCTAssertEqual(
            MouseEventHandler.nativeResizeEdges(from: start, to: start.offsetBy(dx: 80, dy: 30), allowsCentred: true),
            []
        )
        XCTAssertEqual(
            MouseEventHandler.nativeResizeEdges(from: start, to: grown(start, left: 50, right: 50)),
            []
        )
    }

    func testACentredWidthDragWidensTheColumnAroundItsCentre() throws {
        let fixture = try makeFixture(pid: 871_036)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (left, resized, right) = (fixture.tokens[0], fixture.tokens[1], fixture.tokens[2])
        let start = try fixture.frame(resized)
        let leftStart = try fixture.frame(left)
        let rightStart = try fixture.frame(right)

        try fixture.resize(resized, to: grown(start, left: 60, right: 60))

        let frame = try fixture.settledFrame(resized)
        XCTAssertEqual(frame.minX, start.minX - 60, accuracy: 1)
        XCTAssertEqual(frame.width, start.width + 120, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(left).maxX, leftStart.maxX - 60, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(right).minX, rightStart.minX + 60, accuracy: 1)
    }

    func testACentredHeightDragOnAStacksTopWindowTakesOnlyItsInnerEdge() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_037)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, lower) = try upperAndLower(fixture)
        let upperStart = try fixture.frame(upper)
        let lowerStart = try fixture.frame(lower)

        try fixture.resize(upper, to: grown(upperStart, bottom: 50, top: 50))

        let frame = try fixture.settledFrame(upper)
        XCTAssertEqual(frame.maxY, upperStart.maxY, accuracy: 1)
        XCTAssertEqual(frame.height, upperStart.height + 50, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(lower).height, lowerStart.height - 50, accuracy: 1)
    }

    func testACentredHeightDragOnALoneWindowKeepsItAtItsEnd() throws {
        let fixture = try makeFixture(pid: 871_038)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)

        try fixture.resize(lone, to: grown(start, bottom: -75, top: -75))

        let frame = try fixture.settledFrame(lone)
        XCTAssertEqual(frame.height, start.height - 150, accuracy: 1)
        XCTAssertEqual(frame.minY, start.minY, accuracy: 1)
    }

    func testACentredCornerDragTakesBothAxes() throws {
        let fixture = try makeFixture(pid: 871_039)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)

        try fixture.resize(lone, to: grown(start, left: 40, right: 40, bottom: -50, top: -50))

        let frame = try fixture.settledFrame(lone)
        XCTAssertEqual(frame.minX, start.minX - 40, accuracy: 1)
        XCTAssertEqual(frame.width, start.width + 80, accuracy: 1)
        XCTAssertEqual(frame.height, start.height - 100, accuracy: 1)
        XCTAssertEqual(frame.minY, start.minY, accuracy: 1)
    }

    func testAnInwardCentredCornerDragSlidesTheWindowBackToItsEnd() throws {
        let fixture = try makeFixture(pid: 871_051)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)
        let released = grown(start, left: -30, right: -30, bottom: -50, top: -50)
        try fixture.beginDrag(lone)
        fixture.drag(lone, to: released)

        fixture.release(at: released)

        XCTAssertTrue(try fixture.node(lone).hasMoveAnimationsRunning)
        XCTAssertEqual(try fixture.frame(lone).minY, released.minY, accuracy: 1)
        let midway = try fixture.frame(lone, after: 0.08)
        XCTAssertLessThan(midway.minY, released.minY - 1)
        XCTAssertGreaterThan(midway.minY, start.minY + 1)
        XCTAssertEqual(try fixture.settledFrame(lone).minY, start.minY, accuracy: 1)
    }

    func testATabbedColumnsCentredHeightDragSnapsBack() throws {
        let fixture = try makeFixture(stacked: true, pid: 871_040)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let shown = fixture.tokens[0]
        try makeTabbed(fixture, showing: shown)
        let start = try fixture.frame(shown)

        try fixture.resize(shown, to: grown(start, bottom: -60, top: -60))

        XCTAssertEqual(try fixture.settledFrame(shown), start)
        XCTAssertTrue(try fixture.node(shown).height.isAuto)
    }

    func testOnAVerticalStripAnEdgeDragStillSnapsBack() throws {
        let fixture = try makeFixture(pid: 871_090)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        fixture.controller.settings.monitors.updateOrientationSettings(
            MonitorOrientationSettings(
                monitorName: fixture.monitor.name,
                monitorDisplayId: fixture.monitor.displayId,
                orientation: .vertical
            ),
            for: fixture.monitor
        )
        XCTAssertEqual(fixture.handler.liveColumnContext(for: fixture.workspaceId)?.orientation, .vertical)
        let resized = fixture.tokens[1]
        let start = try fixture.frame(resized)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, bottom: 60))

        fixture.release(at: grown(start, bottom: 60))

        XCTAssertEqual(try fixture.frame(resized), start)
    }

    func testWithTheSettingOffACentredDragSnapsBack() throws {
        let fixture = try makeFixture(pid: 871_041)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        fixture.controller.settings.niri.naturalWindowDrag = false
        fixture.controller.settings.gestures.adoptNativeResize = true
        let resized = fixture.tokens[1]
        let start = try fixture.frame(resized)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, left: 60, right: 60))

        fixture.release(at: grown(start, left: 60, right: 60))

        XCTAssertEqual(try fixture.frame(resized), start)
    }

    func testACentredHeightDragOnAStacksMiddleWindowGrowsBothWays() throws {
        let fixture = try makeFixture(stackedThree: true, pid: 871_042)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, middle, lower) = try topToBottom(fixture)
        let upperStart = try fixture.frame(upper)
        let middleStart = try fixture.frame(middle)
        let lowerStart = try fixture.frame(lower)

        try fixture.resize(middle, to: grown(middleStart, bottom: 40, top: 40))

        XCTAssertEqual(try fixture.settledFrame(middle).height, middleStart.height + 80, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(upper).maxY, upperStart.maxY, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(lower).minY, lowerStart.minY, accuracy: 1)
    }

    func testAMiddleWindowsTopEdgeTakesRoomOnlyFromTheWindowAbove() throws {
        let fixture = try makeFixture(stackedThree: true, pid: 871_047)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, middle, lower) = try topToBottom(fixture)
        let upperStart = try fixture.frame(upper)
        let middleStart = try fixture.frame(middle)
        let lowerStart = try fixture.frame(lower)

        try fixture.resize(middle, to: grown(middleStart, top: 50))

        let middleFrame = try fixture.settledFrame(middle)
        XCTAssertEqual(middleFrame.minY, middleStart.minY, accuracy: 1)
        XCTAssertEqual(middleFrame.height, middleStart.height + 50, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(upper).height, upperStart.height - 50, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(upper).maxY, upperStart.maxY, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(lower), lowerStart)
    }

    func testAMiddleWindowsBottomEdgeTakesRoomOnlyFromTheWindowBelow() throws {
        let fixture = try makeFixture(stackedThree: true, pid: 871_048)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, middle, lower) = try topToBottom(fixture)
        let upperStart = try fixture.frame(upper)
        let middleStart = try fixture.frame(middle)
        let lowerStart = try fixture.frame(lower)

        try fixture.resize(middle, to: grown(middleStart, bottom: 50))

        let middleFrame = try fixture.settledFrame(middle)
        XCTAssertEqual(middleFrame.maxY, middleStart.maxY, accuracy: 1)
        XCTAssertEqual(middleFrame.height, middleStart.height + 50, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(lower).height, lowerStart.height - 50, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(lower).minY, lowerStart.minY, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(upper), upperStart)
    }

    func testShrinkingAMiddleWindowFromTheTopGivesTheRoomOnlyToTheWindowAbove() throws {
        let fixture = try makeFixture(stackedThree: true, pid: 871_049)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, middle, lower) = try topToBottom(fixture)
        let upperStart = try fixture.frame(upper)
        let middleStart = try fixture.frame(middle)
        let lowerStart = try fixture.frame(lower)

        try fixture.resize(middle, to: grown(middleStart, top: -40))

        XCTAssertEqual(try fixture.settledFrame(middle).height, middleStart.height - 40, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(upper).height, upperStart.height + 40, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(lower), lowerStart)
    }

    func testAMiddleWindowsEdgeSnapsBackWhenTheWindowAboveCantGiveWay() throws {
        let fixture = try makeFixture(stackedThree: true, pid: 871_050)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, middle, lower) = try topToBottom(fixture)
        let upperStart = try fixture.frame(upper)
        let middleStart = try fixture.frame(middle)
        let lowerStart = try fixture.frame(lower)
        try fixture.node(upper).constraints = WindowSizeConstraints(
            minSize: CGSize(width: 1, height: upperStart.height - 20),
            maxSize: .zero,
            isFixed: false
        )

        try fixture.resize(middle, to: grown(middleStart, top: 50))

        XCTAssertEqual(try fixture.settledFrame(middle), middleStart)
        XCTAssertEqual(try fixture.settledFrame(upper), upperStart)
        XCTAssertEqual(try fixture.settledFrame(lower), lowerStart)
        XCTAssertTrue(try fixture.node(middle).height.isAuto)
    }

    func testAMiddleWindowsEdgeSnapsBackWhenTheWindowAboveCantGrowThatFar() throws {
        let fixture = try makeFixture(stackedThree: true, pid: 871_052)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, middle, lower) = try topToBottom(fixture)
        let upperStart = try fixture.frame(upper)
        let middleStart = try fixture.frame(middle)
        let lowerStart = try fixture.frame(lower)
        try fixture.node(upper).constraints = WindowSizeConstraints(
            minSize: CGSize(width: 1, height: 1),
            maxSize: CGSize(width: 0, height: upperStart.height + 10),
            isFixed: false
        )

        try fixture.resize(middle, to: grown(middleStart, top: -40))

        XCTAssertEqual(try fixture.settledFrame(middle), middleStart)
        XCTAssertEqual(try fixture.settledFrame(upper), upperStart)
        XCTAssertEqual(try fixture.settledFrame(lower), lowerStart)
    }

    func testAFixedHeightNeighbourKeepsAFixedHeightWhenItGivesWay() throws {
        let fixture = try makeFixture(stackedThree: true, pid: 871_053)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (upper, middle, lower) = try topToBottom(fixture)
        let upperStart = try fixture.frame(upper)
        let middleStart = try fixture.frame(middle)
        let lowerStart = try fixture.frame(lower)
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { _ in
            try? fixture.node(upper).height = .fixed(upperStart.height)
            try? fixture.node(middle).height = .fixed(middleStart.height)
        }

        try fixture.resize(middle, to: grown(middleStart, top: 50))

        XCTAssertEqual(try fixture.node(upper).height, .fixed(upperStart.height - 50))
        XCTAssertEqual(try fixture.settledFrame(upper).maxY, upperStart.maxY, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(middle).height, middleStart.height + 50, accuracy: 1)
        XCTAssertEqual(try fixture.settledFrame(lower), lowerStart)
    }

    func testAnOptionPressOnAFixedSizeWindowsEdgeStillMovesIt() throws {
        let fixture = try makeFixture(pid: 871_054)
        fixture.controller.settings.niri.naturalWindowDragModifier = .control
        fixture.controller.settings.gestures.mouseMoveModifierKey = .option
        let pressed = fixture.tokens[1]
        let frame = try fixture.frame(pressed)
        let size = CGSize(width: frame.width, height: frame.height)
        try fixture.node(pressed).constraints = WindowSizeConstraints(minSize: size, maxSize: size, isFixed: true)

        _ = fixture.handler.dispatchMouseDown(
            at: CGPoint(x: frame.maxX - 2, y: frame.midY),
            modifiers: .maskAlternate,
            windowIdUnderPointer: pressed.windowId
        )

        XCTAssertTrue(fixture.handler.state.isMoving)
    }

    func testACentredWidthDragAtTheScreenEdgeGrowsAwayFromIt() throws {
        let fixture = try makeFixture(pid: 871_043)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let resized = fixture.tokens[0]
        let start = try fixture.frame(resized)
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.workspaceId))

        try fixture.resize(resized, to: grown(start, left: 60, right: 60))

        let frame = try fixture.settledFrame(resized)
        XCTAssertEqual(frame.minX, context.workingFrame.minX + context.gaps, accuracy: 1)
        XCTAssertEqual(frame.width, start.width + 120, accuracy: 1)
    }

    func testACentredWidthDragStoppedByAMinimumWidthStaysCentred() throws {
        let fixture = try makeFixture(pid: 871_044)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let resized = fixture.tokens[1]
        try fixture.node(resized).constraints = WindowSizeConstraints(
            minSize: CGSize(width: 450, height: 1),
            maxSize: .zero,
            isFixed: false
        )
        let start = try fixture.frame(resized)

        try fixture.resize(resized, to: grown(start, left: -100, right: -100))

        let frame = try fixture.settledFrame(resized)
        XCTAssertEqual(frame.width, 450, accuracy: 1)
        XCTAssertEqual(frame.midX, start.midX, accuracy: 1)
    }

    func testWithAnotherStackModifierAnOptionPressOnAWindowEdgeIsLeftToMacOS() throws {
        let fixture = try makeFixture(pid: 871_045)
        fixture.controller.settings.niri.naturalWindowDragModifier = .control
        fixture.controller.settings.gestures.mouseMoveModifierKey = .option
        let pressed = fixture.tokens[1]
        let frame = try fixture.frame(pressed)

        XCTAssertFalse(fixture.handler.dispatchMouseDown(
            at: CGPoint(x: frame.maxX - 2, y: frame.midY),
            modifiers: .maskAlternate,
            windowIdUnderPointer: pressed.windowId
        ))
        XCTAssertFalse(fixture.handler.state.isMoving)

        _ = fixture.handler.dispatchMouseDown(
            at: frame.center,
            modifiers: .maskAlternate,
            windowIdUnderPointer: pressed.windowId
        )
        XCTAssertTrue(fixture.handler.state.isMoving)
    }

    func testALoneWindowWithoutAHeightYetSitsAtTheColumnStart() throws {
        let fixture = try makeFixture(pid: 871_046)
        let window = try fixture.node(fixture.tokens[1])
        window.height = .fixed(300)
        window.rest(atTop: true, in: try fixture.column(fixture.tokens[1]))
        window.resolvedHeight = nil
        window.frame = nil

        let offsets = fixture.engine.projectedSecondaryOffsets(
            for: [window],
            effectiveTabbed: false,
            gaps: 8,
            orientation: .horizontal,
            availableSpan: 900
        )

        XCTAssertEqual(offsets, [8])
    }

    @discardableResult
    private func makeTabbed(_ fixture: Fixture, showing shown: WindowToken) throws -> NiriContainer {
        let column = try fixture.column(shown)
        fixture.engine.tabbedColumnsFillHeight = true
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { _ in
            column.displayMode = .tabbed
            column.setActiveTileIdx(0)
            fixture.engine.updateTabbedColumnVisibility(column: column)
            column.cachedWidth = 0
        }
        _ = fixture.frames()
        fixture.applyPendingFrames()
        return column
    }

    private func topToBottom(_ fixture: Fixture) throws -> (WindowToken, WindowToken, WindowToken) {
        let frames = fixture.frames()
        let ordered = fixture.tokens.sorted { (frames[$0]?.midY ?? 0) > (frames[$1]?.midY ?? 0) }
        return (ordered[0], ordered[1], ordered[2])
    }

    private func upperAndLower(_ fixture: Fixture) throws -> (WindowToken, WindowToken) {
        let (first, second) = (fixture.tokens[0], fixture.tokens[1])
        return try fixture.frame(first).midY > fixture.frame(second).midY ? (first, second) : (second, first)
    }

    private func grown(
        _ frame: CGRect,
        left: CGFloat = 0,
        right: CGFloat = 0,
        bottom: CGFloat = 0,
        top: CGFloat = 0
    ) -> CGRect {
        CGRect(
            x: frame.minX - left,
            y: frame.minY - bottom,
            width: frame.width + left + right,
            height: frame.height + bottom + top
        )
    }

    private func blockRefreshes(_ fixture: Fixture) -> Task<Void, Never> {
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [fixture.workspaceId]
        )
        return blocker
    }

    private func unblockRefreshes(_ fixture: Fixture, blocker: Task<Void, Never>) {
        blocker.cancel()
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = nil
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = nil
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
    }

    private func makeFixture(
        stacked: Bool = false,
        stackedThree: Bool = false,
        portrait: Bool = false,
        pid: pid_t
    ) throws -> Fixture {
        let monitorFrame = portrait
            ? CGRect(x: workingFrame.minX, y: workingFrame.minY, width: workingFrame.height, height: workingFrame.width)
            : workingFrame
        let controller = WindowAdmissionTestSupport.controller(prefix: "NiriNaturalEdgeResizeTests")
        addTeardownBlock { @MainActor [controller] in
            controller.hasStartedServices = false
            controller.layoutRefreshController.resetState()
            controller.mouseEventHandler.cleanup()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
        }
        let monitor = Monitor(
            id: .init(displayId: 87_101),
            displayId: 87_101,
            frame: monitorFrame,
            visibleFrame: monitorFrame,
            hasNotch: false,
            name: "Niri Live Edge Resize"
        )
        controller.settings.niri.naturalWindowDrag = true
        controller.settings.gestures.adoptNativeResize = false
        controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            )
        ]
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let tokens = (0 ..< 3).map { WindowToken(pid: pid, windowId: Int(pid) + 100 + $0) }
        for token in tokens {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        controller.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let first = engine.addWindow(token: tokens[0], to: workspaceId, afterSelection: nil)
        if stacked || stackedThree {
            let second = NiriWindow(token: tokens[1])
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                engine.attachTransferredWindow(second, stackedWith: first, after: true, in: workspaceId, state: &state)
                if stackedThree {
                    engine.attachTransferredWindow(
                        NiriWindow(token: tokens[2]),
                        stackedWith: second,
                        after: true,
                        in: workspaceId,
                        state: &state
                    )
                }
            }
            if !stackedThree {
                _ = engine.addWindow(token: tokens[2], to: workspaceId, afterSelection: first.id)
            }
        } else {
            let second = engine.addWindow(token: tokens[1], to: workspaceId, afterSelection: first.id)
            _ = engine.addWindow(token: tokens[2], to: workspaceId, afterSelection: second.id)
        }
        for column in engine.columns(in: workspaceId) {
            column.width = .proportion(1.0 / 3.0)
            column.cachedWidth = 0
        }
        let fixture = Fixture(
            controller: controller,
            workspaceId: workspaceId,
            monitor: monitor,
            tokens: tokens,
            orientation: portrait ? .vertical : .horizontal
        )
        let frames = fixture.frames()
        fixture.confirmLayout()
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard let token = tokens.first(where: { $0.windowId == Int(windowId) }) else { return nil }
            return WindowServerInfo(id: windowId, pid: token.pid, level: 0, frame: frames[token] ?? .zero)
        }
        controller.layoutRefreshController.resetState()
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        controller.hasStartedServices = true
        return fixture
    }
}
