// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriFusionEdgeResizeTests: NiriInteractionTestCase {
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

        var pixel: CGFloat {
            1 / engine.displayScale(in: workspaceId)
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
            try frame(token, at: .infinity)
        }

        func frame(_ token: WindowToken, at time: TimeInterval) throws -> CGRect {
            let gap = controller.innerGap(for: monitor)
            return try XCTUnwrap(engine.calculateLayoutWithVisibility(
                state: manager.niriViewportState(for: workspaceId),
                workspaceId: workspaceId,
                monitorFrame: controller.insetWorkingFrame(for: monitor),
                gaps: (horizontal: gap, vertical: gap),
                orientation: orientation,
                animationTime: time
            ).frames[token])
        }

        func confirmLayout() {
            for (token, frame) in frames() {
                controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame)
            }
        }

        func beginDrag(_ token: WindowToken, at press: CGPoint? = nil, draggedTo: CGPoint? = nil) throws {
            handler.retireNativeTitleBarDragAtInputBoundary()
            applyPendingFrames()
            handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            let start = try frame(token)
            handler.nativeWindowFrameProvider = { _ in start }
            XCTAssertFalse(handler.dispatchMouseDown(
                at: press ?? start.center,
                modifiers: [],
                windowIdUnderPointer: token.windowId
            ))
            let pressed = press ?? start.center
            let dragged = orientation == .horizontal
                ? CGPoint(x: (pressed.x + FrameTolerance.frameWrite).nextUp, y: pressed.y)
                : CGPoint(x: pressed.x, y: (pressed.y + FrameTolerance.frameWrite).nextUp)
            handler.dispatchMouseDragged(at: draggedTo ?? dragged)
            XCTAssertEqual(phase, .dragging)
        }

        func drag(_ token: WindowToken, to observed: CGRect) {
            handler.nativeWindowFrameProvider = { _ in observed }
            controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
        }

        func release(at observed: CGRect, cursor: CGPoint? = nil) {
            handler.nativeWindowFrameProvider = { _ in observed }
            handler.dispatchMouseUp(at: cursor ?? observed.center)
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
            let start = try frame(token)
            let edges = MouseEventHandler.nativeResizeEdges(from: start, to: observed, allowsCentred: true)
            let press = orientation == .vertical && edges.hasVertical && !edges.hasHorizontal
                ? CGPoint(x: start.midX, y: edges.contains(.top) ? start.maxY - pixel : start.minY + pixel) : nil
            try beginDrag(token, at: press)
            drag(token, to: observed)
            let cursor = press.map {
                CGPoint(x: $0.x, y: $0.y + (edges.contains(.top)
                        ? observed.maxY - start.maxY : observed.minY - start.minY))
            }
            release(at: observed, cursor: cursor)
            applyPendingFrames()
        }

        func resizeFromEdge(_ token: WindowToken, edges: ResizeEdge, to observed: CGRect) throws {
            let start = try frame(token)
            let press = CGPoint(
                x: edges.contains(.right) ? start.maxX - pixel
                    : edges.contains(.left) ? start.minX + pixel : start.midX,
                y: edges.contains(.top) ? start.maxY - pixel
                    : edges.contains(.bottom) ? start.minY + pixel : start.midY
            )
            let travel = CGPoint(
                x: edges.contains(.right) ? observed.maxX - start.maxX
                    : edges.contains(.left) ? observed.minX - start.minX : 0,
                y: edges.contains(.top) ? observed.maxY - start.maxY
                    : edges.contains(.bottom) ? observed.minY - start.minY : 0
            )
            let dragged = CGPoint(
                x: travel.x > 0 ? (press.x + FrameTolerance.frameWrite).nextUp
                    : travel.x < 0 ? (press.x - FrameTolerance.frameWrite).nextDown : press.x,
                y: travel.y > 0 ? (press.y + FrameTolerance.frameWrite).nextUp
                    : travel.y < 0 ? (press.y - FrameTolerance.frameWrite).nextDown : press.y
            )
            try beginDrag(token, at: press, draggedTo: dragged)
            drag(token, to: observed)
            release(at: observed, cursor: CGPoint(x: press.x + travel.x, y: press.y + travel.y))
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
        let growth: CGFloat = 100
        try fixture.beginDrag(lower)
        fixture.drag(lower, to: grown(lowerStart, top: growth))

        fixture.release(at: grown(lowerStart, top: growth))

        XCTAssertTrue(try fixture.node(upper).hasMoveAnimationsRunning)
        XCTAssertFalse(try fixture.node(lower).hasMoveAnimationsRunning)
        XCTAssertEqual(try fixture.frame(upper), upperStart)
        let spring = try XCTUnwrap(fixture.node(upper).heightAnimation).animation
        let nextFrame = min(spring.duration / 2, 1 / fixture.engine.displayRefreshRate(in: fixture.workspaceId))
        let midway = try fixture.frame(upper, at: spring.startTime + nextFrame)
        XCTAssertEqual(midway.maxY, upperStart.maxY, accuracy: fixture.pixel)
        XCTAssertLessThan(midway.height, upperStart.height - fixture.pixel)
        XCTAssertGreaterThan(midway.height, upperStart.height - growth + fixture.pixel)
        let settled = try fixture.settledFrame(upper)
        XCTAssertEqual(settled.maxY, upperStart.maxY, accuracy: fixture.pixel)
        XCTAssertEqual(settled.height, upperStart.height - growth, accuracy: fixture.pixel)
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

    func testPortraitPrimaryReleaseSlidesNeighborsFromTheirOldFrames() throws {
        let fixture = try makeFixture(portrait: true, pid: 871_020)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let resized = fixture.tokens[1]
        let before = fixture.frames()
        let start = try XCTUnwrap(before[resized])
        let growth = start.height / 4
        let observed = grown(start, bottom: growth)
        let press = CGPoint(x: start.midX, y: start.minY + fixture.pixel)
        try fixture.beginDrag(resized, at: press)
        fixture.drag(resized, to: observed)
        XCTAssertEqual(fixture.frames(), before)
        XCTAssertNil(fixture.engine.interactiveResize)

        fixture.release(at: observed, cursor: CGPoint(x: press.x, y: press.y - growth))

        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertFalse(try fixture.node(resized).hasMoveAnimationsRunning)
        XCTAssertEqual(try fixture.column(resized).cachedHeight, observed.height, accuracy: fixture.pixel)
        XCTAssertEqual(try fixture.settledFrame(resized).maxY, start.maxY, accuracy: fixture.pixel)
        let moved = try fixture.tokens.filter { token in
            guard token != resized else { return false }
            let settled = try fixture.settledFrame(token)
            let old = try XCTUnwrap(before[token])
            return abs(settled.minY - old.minY) > fixture.pixel
        }
        XCTAssertFalse(moved.isEmpty)
        for token in moved {
            let animation = try XCTUnwrap(fixture.node(token).moveYAnimation).animation
            XCTAssertEqual(try fixture.frame(token, at: animation.startTime), try XCTUnwrap(before[token]))
        }
    }

    func testPortraitSecondaryReleaseAnimatesTheNeighborsNearEdgeAndKeepsItsFarEdge() throws {
        for (index, leading) in [false, true].enumerated() {
            let fixture = try makeFixture(stacked: true, portrait: true, pid: pid_t(872_001 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let ordered = try fixture.tokens.prefix(2).sorted { try fixture.frame($0).midX < fixture.frame($1).midX }
            let resized = ordered[leading ? 1 : 0]
            let neighbor = ordered[leading ? 0 : 1]
            let start = try fixture.frame(resized)
            let neighborStart = try fixture.frame(neighbor)
            let growth = min(start.width, neighborStart.width) / 8
            let press = CGPoint(x: leading ? start.minX + fixture.pixel : start.maxX - fixture.pixel, y: start.midY)
            let cursor = CGPoint(x: press.x + (leading ? -growth : growth), y: press.y)
            let observed = leading ? grown(start, left: growth) : grown(start, right: growth)
            try fixture.beginDrag(
                resized, at: press,
                draggedTo: CGPoint(
                    x: leading ? (press.x - FrameTolerance.frameWrite).nextDown
                        : (press.x + FrameTolerance.frameWrite).nextUp,
                    y: press.y
                )
            )
            fixture.drag(resized, to: observed)
            XCTAssertEqual(try fixture.frame(neighbor), neighborStart)
            XCTAssertFalse(try fixture.node(neighbor).hasMoveAnimationsRunning)

            fixture.release(at: observed, cursor: cursor)

            XCTAssertFalse(try fixture.node(resized).hasMoveAnimationsRunning)
            XCTAssertEqual(try fixture.frame(resized).width, start.width + growth, accuracy: fixture.pixel)
            let spring = try XCTUnwrap(fixture.node(neighbor).widthAnimation).animation
            let initial = try fixture.frame(neighbor, at: spring.startTime)
            XCTAssertEqual(initial.minX, neighborStart.minX, accuracy: fixture.pixel)
            XCTAssertEqual(initial.width, neighborStart.width, accuracy: fixture.pixel)
            let nextFrame = min(spring.duration / 2, 1 / fixture.engine.displayRefreshRate(in: fixture.workspaceId))
            let midway = try fixture.frame(neighbor, at: spring.startTime + nextFrame)
            XCTAssertEqual(
                leading ? midway.minX : midway.maxX,
                leading ? neighborStart.minX : neighborStart.maxX,
                accuracy: fixture.pixel
            )
            XCTAssertEqual(midway.minY, neighborStart.minY, accuracy: fixture.pixel)
            XCTAssertEqual(midway.height, neighborStart.height, accuracy: fixture.pixel)
            XCTAssertLessThan(midway.width, neighborStart.width - fixture.pixel)
            XCTAssertGreaterThan(midway.width, neighborStart.width - growth + fixture.pixel)
            let settled = try fixture.settledFrame(neighbor)
            XCTAssertEqual(settled.width, neighborStart.width - growth, accuracy: fixture.pixel)
            XCTAssertEqual(
                leading ? settled.minX : settled.maxX,
                leading ? neighborStart.minX : neighborStart.maxX,
                accuracy: fixture.pixel
            )
        }
    }

    func testPortraitOuterSecondaryEdgesKeepTheRowFullWhileCornersChangeOnlyItsPrimarySpan() throws {
        var scenario = 0
        for leading in [false, true] {
            for corner in [false, true] {
                let fixture = try makeFixture(stacked: true, portrait: true, pid: pid_t(872_011 + scenario))
                scenario += 1
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                let ordered = try fixture.tokens.prefix(2)
                    .sorted { try fixture.frame($0).midX < fixture.frame($1).midX }
                let resized = ordered[leading ? 0 : 1]
                let neighbor = ordered[leading ? 1 : 0]
                let start = try fixture.frame(resized)
                let neighborStart = try fixture.frame(neighbor)
                let reduction = start.width / 8
                let primaryGrowth = corner ? start.height / 8 : 0
                let edges: ResizeEdge = leading ? .left : .right
                let observed = leading
                    ? grown(start, left: -reduction, top: primaryGrowth)
                    : grown(start, right: -reduction, top: primaryGrowth)

                try fixture.resizeFromEdge(resized, edges: corner ? edges.union(.top) : edges, to: observed)

                let settled = try fixture.settledFrame(resized)
                XCTAssertEqual(settled.width, start.width, accuracy: fixture.pixel)
                XCTAssertEqual(settled.minX, start.minX, accuracy: fixture.pixel)
                XCTAssertEqual(settled.height, start.height + primaryGrowth, accuracy: fixture.pixel)
                XCTAssertEqual(settled.minY, start.minY, accuracy: fixture.pixel)
                XCTAssertEqual(try fixture.settledFrame(neighbor).width, neighborStart.width, accuracy: fixture.pixel)
                XCTAssertTrue(try fixture.node(resized).windowWidth.isAuto)
            }
        }
    }

    func testPortraitCenteredSecondaryResizesUseOnlyAvailableInnerEdges() throws {
        var scenario = 0
        for index in 0 ..< 3 {
            for direction in [CGFloat(-1), 1] {
                let fixture = try makeFixture(stackedThree: true, portrait: true, pid: pid_t(872_021 + scenario))
                scenario += 1
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                let before = fixture.frames()
                let ordered = try fixture.tokens.sorted {
                    try XCTUnwrap(before[$0]).midX < XCTUnwrap(before[$1]).midX
                }
                let resized = ordered[index]
                let start = try XCTUnwrap(before[resized])
                let travel = direction * start.width / 8

                try fixture.resizeFromEdge(resized, edges: [.left, .right], to: start.insetBy(dx: -travel, dy: 0))

                for (position, token) in ordered.enumerated() {
                    let original = try XCTUnwrap(before[token])
                    let change: CGFloat = position == index ? (index == 1 ? 2 : 1) * travel
                        : abs(position - index) == 1 ? -travel : 0
                    let settled = try fixture.settledFrame(token)
                    XCTAssertEqual(settled.width, original.width + change, accuracy: fixture.pixel)
                    XCTAssertEqual(settled.height, original.height, accuracy: fixture.pixel)
                }
                XCTAssertEqual(
                    try fixture.settledFrame(ordered[0]).minX,
                    try XCTUnwrap(before[ordered[0]]).minX,
                    accuracy: fixture.pixel
                )
                XCTAssertEqual(
                    try fixture.settledFrame(ordered[2]).maxX,
                    try XCTUnwrap(before[ordered[2]]).maxX,
                    accuracy: fixture.pixel
                )
            }
        }
    }

    func testPortraitMiddleSecondaryEdgesChangeOnlyTheNearestNeighborAndKeepFixedWidths() throws {
        var scenario = 0
        for leading in [false, true] {
            for direction in [CGFloat(-1), 1] {
                let fixture = try makeFixture(stackedThree: true, portrait: true, pid: pid_t(872_031 + scenario))
                scenario += 1
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                let before = fixture.frames()
                let ordered = try fixture.tokens.sorted { try XCTUnwrap(before[$0]).midX < XCTUnwrap(before[$1]).midX }
                let resized = ordered[1]
                let neighbor = ordered[leading ? 0 : 2]
                let untouched = ordered[leading ? 2 : 0]
                let start = try XCTUnwrap(before[resized])
                let neighborStart = try XCTUnwrap(before[neighbor])
                let growth = direction * min(start.width, neighborStart.width) / 8
                let neighborNode = try fixture.node(neighbor)
                fixture.manager.withNiriViewportState(for: fixture.workspaceId) { _ in
                    neighborNode.windowWidth = .fixed(neighborStart.width)
                }
                fixture.applyPendingFrames()

                try fixture.resizeFromEdge(
                    resized, edges: leading ? .left : .right,
                    to: leading ? grown(start, left: growth) : grown(start, right: growth)
                )

                XCTAssertEqual(try fixture.settledFrame(resized).width, start.width + growth, accuracy: fixture.pixel)
                XCTAssertEqual(
                    try fixture.settledFrame(neighbor).width,
                    neighborStart.width - growth,
                    accuracy: fixture.pixel
                )
                XCTAssertEqual(neighborNode.windowWidth, .fixed(neighborStart.width - growth))
                XCTAssertEqual(try fixture.settledFrame(untouched), try XCTUnwrap(before[untouched]))
            }
        }
    }

    func testPortraitSecondaryRefusalRestoresAllWidthSpecificationsAndFrames() throws {
        for (index, refusesGrowth) in [false, true].enumerated() {
            let fixture = try makeFixture(stackedThree: true, portrait: true, pid: pid_t(872_041 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let before = fixture.frames()
            let ordered = try fixture.tokens.sorted { try XCTUnwrap(before[$0]).midX < XCTUnwrap(before[$1]).midX }
            let resized = ordered[1]
            let neighbor = ordered[0]
            let start = try XCTUnwrap(before[resized])
            let neighborStart = try XCTUnwrap(before[neighbor])
            let allowance = min(start.width, neighborStart.width) / 16
            let growth = refusesGrowth ? -2 * allowance : 2 * allowance
            let widths = try ordered.map { try fixture.node($0).windowWidth }
            try fixture.node(neighbor).constraints = WindowSizeConstraints(
                minSize: CGSize(width: refusesGrowth ? 1 : neighborStart.width - allowance, height: 1),
                maxSize: CGSize(width: refusesGrowth ? neighborStart.width + allowance : 0, height: 0),
                isFixed: false
            )

            try fixture.resizeFromEdge(resized, edges: .left, to: grown(start, left: growth))

            for (position, token) in ordered.enumerated() {
                XCTAssertEqual(try fixture.settledFrame(token), try XCTUnwrap(before[token]))
                XCTAssertEqual(try fixture.node(token).windowWidth, widths[position])
            }
        }
    }

    func testPortraitLoneSecondaryShrinkIsKeptButTabbedSecondaryEdgesKeepFilling() throws {
        for (index, tabbed) in [false, true].enumerated() {
            let fixture = try makeFixture(stacked: tabbed, portrait: true, pid: pid_t(872_051 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            if tabbed { try makeTabbed(fixture, showing: token) }
            let start = try fixture.frame(token)
            let reduction = start.width / 8

            try fixture.resizeFromEdge(token, edges: [.left, .right], to: start.insetBy(dx: reduction / 2, dy: 0))

            let settled = try fixture.settledFrame(token)
            XCTAssertEqual(settled.width, tabbed ? start.width : start.width - reduction, accuracy: fixture.pixel)
            XCTAssertEqual(settled.minX, start.minX, accuracy: fixture.pixel)
            XCTAssertEqual(settled.height, start.height, accuracy: fixture.pixel)
        }
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

    func testALoneWindowKeepsAShorterHeightFromEitherEdgeAndRestsAtTheColumnsStart() throws {
        for (pid, fromTheTop) in [(pid_t(871_008), true), (pid_t(871_108), false)] {
            let fixture = try makeFixture(pid: pid)
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let lone = fixture.tokens[1]
            let start = try fixture.frame(lone)
            let shorter = fromTheTop ? grown(start, top: -150) : grown(start, bottom: -150)

            try fixture.resize(lone, to: shorter)

            XCTAssertEqual(
                try fixture.settledFrame(lone),
                CGRect(x: start.minX, y: start.minY, width: start.width, height: shorter.height),
                "\(fromTheTop)"
            )
            XCTAssertEqual(try fixture.node(lone).height, .fixed(shorter.height), "\(fromTheTop)")
        }
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
        fixture.controller.settings.niri.edgePeekPercent = 3
        fixture.controller.updateNiriConfig(edgePeekShare: fixture.controller.edgePeekShare)
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

    func testPortraitPrimaryReleaseHonorsThePeekAndHeightConstraints() throws {
        let fixture = try makeFixture(portrait: true, pid: 871_191)
        fixture.controller.motionPolicy.animationsEnabled = false
        fixture.controller.settings.niri.edgePeekPercent = 3
        fixture.controller.updateNiriConfig(edgePeekShare: fixture.controller.edgePeekShare)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let resized = fixture.tokens[1]
        let start = try fixture.frame(resized)
        let gap = fixture.controller.innerGap(for: fixture.monitor)
        let span = fixture.controller.insetWorkingFrame(for: fixture.monitor).height
        let share = CGFloat(fixture.controller.settings.niri.edgePeekPercent) / 100
        let view = fixture.monitor.frame
        let working = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        let peek = (view.height * share).rounded()
        let cap = min(working.maxY, view.maxY - peek) - max(working.minY, view.minY + peek) - 2 * gap
        let observed = grown(start, top: span)
        try fixture.resize(resized, to: observed)
        XCTAssertEqual(try fixture.settledFrame(resized).height, cap, accuracy: fixture.pixel)

        let minimum = start.height / 2
        let maximum = start.height
        try fixture.node(resized).constraints = WindowSizeConstraints(
            minSize: CGSize(width: 0, height: minimum),
            maxSize: CGSize(width: 0, height: maximum),
            isFixed: false
        )
        fixture.handler.retireNativeTitleBarDragAtInputBoundary()
        try fixture.resize(resized, to: grown(try fixture.frame(resized), top: span))
        XCTAssertEqual(try fixture.settledFrame(resized).height, maximum, accuracy: fixture.pixel)
        fixture.handler.retireNativeTitleBarDragAtInputBoundary()
        let current = try fixture.frame(resized)
        try fixture.resize(resized, to: grown(current, top: minimum / 2 - current.height))
        XCTAssertEqual(try fixture.settledFrame(resized).height, minimum, accuracy: fixture.pixel)
    }

    func testPortraitOptionPressesStayNativeAndOnlyResizeEdgesExcludeLiveMovement() throws {
        for index in 0 ..< 10 {
            let fixture = try makeFixture(portrait: true, pid: pid_t(871_200 + index))
            let token = fixture.tokens[1]
            let frame = try fixture.frame(token)
            let edgeInset = NiriLayoutEngine.doubleClickEdgeInset / 2
            let point: CGPoint = switch index {
            case 0: CGPoint(x: frame.midX, y: frame.minY + edgeInset)
            case 1: CGPoint(x: frame.midX, y: frame.maxY - edgeInset)
            case 2: frame.center
            case 3: CGPoint(x: frame.midX, y: frame.maxY - NiriLayoutEngine.doubleClickTitleBarDepth / 2)
            case 4: CGPoint(x: frame.minX + edgeInset, y: frame.midY)
            case 5: CGPoint(x: frame.maxX - edgeInset, y: frame.midY)
            case 6: CGPoint(x: frame.minX + edgeInset, y: frame.minY + edgeInset)
            case 7: CGPoint(x: frame.maxX - edgeInset, y: frame.minY + edgeInset)
            case 8: CGPoint(x: frame.minX + edgeInset, y: frame.maxY - edgeInset)
            default: CGPoint(x: frame.maxX - edgeInset, y: frame.maxY - edgeInset)
            }
            XCTAssertFalse(fixture.handler.dispatchMouseDown(
                at: point, modifiers: .maskAlternate, windowIdUnderPointer: token.windowId
            ))
            let isResizePress = index != 2 && index != 3
            XCTAssertFalse(fixture.handler.state.isMoving)
            XCTAssertNil(fixture.engine.interactiveMove)
            XCTAssertNil(fixture.handler.tapInputs.capturedInteractionButton)
            XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.token, token)
            if isResizePress {
                fixture.handler.dispatchMouseDragged(at: CGPoint(
                    x: index >= 4 ? (point.x + FrameTolerance.frameWrite).nextUp : point.x,
                    y: index < 2 || index >= 6 ? (point.y + FrameTolerance.frameWrite).nextUp : point.y
                ))
                XCTAssertFalse(fixture.handler.isLiveColumnDragActive)
                XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.canStartLiveNiriDrag, false)
                XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.liveStartFrame)
                XCTAssertTrue(fixture.handler.livePointer.samples.isEmpty)
            } else {
                fixture.handler.dispatchMouseDragged(at: CGPoint(
                    x: (point.x + FrameTolerance.frameWrite).nextUp, y: point.y
                ))
                XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.canStartLiveNiriDrag, true)
                XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.liveStartFrame, frame)
            }
        }
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

    func testNativeEdgeResizesAdopt() throws {
        let fixture = try makeFixture(pid: 871_015)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let resized = fixture.tokens[1]
        let start = try fixture.frame(resized)
        try fixture.beginDrag(resized)
        fixture.drag(resized, to: grown(start, right: 100))

        fixture.release(at: grown(start, right: 100))

        XCTAssertEqual(try fixture.column(resized).cachedWidth, start.width + 100, accuracy: 1)
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

    func testACentredHeightDragOnALoneWindowIsKept() throws {
        let fixture = try makeFixture(pid: 871_038)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)
        let shorter = grown(start, bottom: -75, top: -75)

        try fixture.resize(lone, to: shorter)

        XCTAssertEqual(
            try fixture.settledFrame(lone),
            CGRect(x: start.minX, y: start.minY, width: start.width, height: shorter.height)
        )
    }

    func testACentredCornerDragOnALoneWindowTakesTheWidthAndTheHeight() throws {
        let fixture = try makeFixture(pid: 871_039)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)
        let released = grown(start, left: 40, right: 40, bottom: -50, top: -50)

        try fixture.resize(lone, to: released)

        let frame = try fixture.settledFrame(lone)
        let onePixel = 1 / fixture.controller.backingScaleFactor(for: fixture.monitor)
        XCTAssertEqual(frame.minX, released.minX, accuracy: onePixel)
        XCTAssertEqual(frame.size, released.size)
        XCTAssertEqual(frame.minY, start.minY)
    }

    func testAnInwardCentredCornerDragOnALoneWindowKeepsTheShorterHeight() throws {
        let fixture = try makeFixture(pid: 871_051)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let lone = fixture.tokens[1]
        let start = try fixture.frame(lone)
        let released = grown(start, left: -30, right: -30, bottom: -50, top: -50)
        try fixture.beginDrag(lone)
        fixture.drag(lone, to: released)

        fixture.release(at: released)

        let settled = try fixture.settledFrame(lone)
        let onePixel = 1 / fixture.controller.backingScaleFactor(for: fixture.monitor)
        XCTAssertEqual(settled.minX, released.minX, accuracy: onePixel)
        XCTAssertEqual(settled.size, released.size)
        XCTAssertEqual(settled.minY, start.minY)
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

    func testPortraitTopAndBottomEdgeResizesKeepTheOppositeEdge() throws {
        for top in [false, true] {
            let fixture = try makeFixture(portrait: true, pid: top ? 871_090 : 871_091)
            fixture.controller.motionPolicy.animationsEnabled = false
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let resized = fixture.tokens[1]
            let start = try fixture.frame(resized)
            let growth = start.height / 4
            let observed = grown(start, bottom: top ? 0 : growth, top: top ? growth : 0)
            let press = CGPoint(x: start.midX, y: top ? start.maxY - fixture.pixel : start.minY + fixture.pixel)
            try fixture.beginDrag(resized, at: press)
            fixture.drag(resized, to: observed)
            fixture.release(at: observed, cursor: CGPoint(x: press.x, y: press.y + (top ? growth : -growth)))
            let settled = try fixture.settledFrame(resized)
            XCTAssertEqual(settled.height, observed.height, accuracy: fixture.pixel)
            XCTAssertEqual(top ? settled.minY : settled.maxY, top ? start.minY : start.maxY, accuracy: fixture.pixel)
            XCTAssertEqual(settled.width, start.width, accuracy: fixture.pixel)
            XCTAssertNil(fixture.engine.interactiveResize)
            XCTAssertEqual(fixture.phase, .awaitingCorrection)
        }
    }

    func testPortraitCenteredPrimaryResizePreservesItsCenterWithTheLegacySettingOff() throws {
        for growing in [false, true] {
            let fixture = try makeFixture(portrait: true, pid: growing ? 871_041 : 871_092)
            fixture.controller.motionPolicy.animationsEnabled = false
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let resized = fixture.tokens[1]
            let start = try fixture.frame(resized)
            let growth = start.height / 8 * (growing ? 1 : -1)
            let observed = grown(start, bottom: growth, top: growth)
            let press = CGPoint(x: start.midX, y: start.maxY - fixture.pixel)
            try fixture.beginDrag(resized, at: press)
            fixture.drag(resized, to: observed)
            fixture.release(at: observed, cursor: CGPoint(x: press.x, y: press.y + growth))
            let settled = try fixture.settledFrame(resized)
            XCTAssertEqual(settled.height, observed.height, accuracy: fixture.pixel)
            XCTAssertEqual(settled.midY, start.midY, accuracy: fixture.pixel)
            XCTAssertEqual(settled.width, start.width, accuracy: fixture.pixel)
        }
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

    func testAnOptionPressOnAFixedSizeWindowsEdgeStartsNoMove() throws {
        let fixture = try makeFixture(pid: 871_054)
        let pressed = fixture.tokens[1]
        let frame = try fixture.frame(pressed)
        let size = CGSize(width: frame.width, height: frame.height)
        try fixture.node(pressed).constraints = WindowSizeConstraints(minSize: size, maxSize: size, isFixed: true)

        _ = fixture.handler.dispatchMouseDown(
            at: CGPoint(x: frame.maxX - 2, y: frame.midY),
            modifiers: .maskAlternate,
            windowIdUnderPointer: pressed.windowId
        )

        XCTAssertFalse(fixture.handler.state.isMoving)
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

    func testAnOptionPressOnAWindowEdgeIsLeftToMacOS() throws {
        let fixture = try makeFixture(pid: 871_045)
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
        XCTAssertFalse(fixture.handler.state.isMoving)
    }

    @discardableResult
    private func makeTabbed(_ fixture: Fixture, showing shown: WindowToken) throws -> NiriContainer {
        let column = try fixture.column(shown)
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
        let blocker = WindowAdmissionTestSupport.parkedTask()
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
        let controller = WindowAdmissionTestSupport.controller(prefix: "NiriFusionEdgeResizeTests")
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
        controller.settings.niri.edgePeekPercent = 0
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
        controller.updateNiriConfig(edgePeekShare: controller.edgePeekShare)
        controller.mouseEventHandler.topmostWindowIdProvider = { _ in nil }
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
            if portrait {
                column.height = .proportion(1.0 / 3.0)
                column.cachedHeight = 0
            }
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
