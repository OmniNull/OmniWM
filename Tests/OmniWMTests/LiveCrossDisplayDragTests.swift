// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

extension CrossDisplayDragTests {
    @MainActor
    struct LiveCrossDisplayFixture {
        let base: Fixture
        let tokens: [WindowToken]
        let refreshTask: Task<Void, Never>
        let refreshCompletion: AsyncStream<Void>.Continuation
        let sourceRatio: CGFloat = 3 / 4

        var controller: WMController {
            base.controller
        }

        var manager: WorkspaceManager {
            base.manager
        }

        var handler: MouseEventHandler {
            base.handler
        }

        var engine: DwindleLayoutEngine {
            base.dwindle
        }

        var dragged: WindowToken {
            tokens[1]
        }

        func expectedFrames(index: Int, transferred: Bool) -> [WindowToken: CGRect] {
            let monitor = controller.layoutRefreshController.buildMonitorSnapshot(for: base.monitors[index])
            let area = monitor.workingFrame
            let members = index == 0
                ? (transferred ? [tokens[0]] : [tokens[0], dragged])
                : (transferred ? [tokens[2], dragged] : [tokens[2]])
            if members.count == 1 {
                return [members[0]: engine.settings.singleWindowFit.frame(in: monitor.borderSafeFillFrame)]
            }
            let cut = area.width * (index == 0 ? sourceRatio : 1) / 2
            let first = CGRect(x: area.minX, y: area.minY, width: cut, height: area.height)
            let second = CGRect(x: area.minX + cut, y: area.minY, width: area.width - cut, height: area.height)
            return [
                members[0]: DwindleGapCalculator.applyGaps(
                    nodeRect: first,
                    tilingArea: area,
                    settings: engine.settings
                ),
                members[1]: DwindleGapCalculator.applyGaps(
                    nodeRect: second,
                    tilingArea: area,
                    settings: engine.settings
                )
            ]
        }

        func crossingPoint() throws -> CGPoint {
            let frame = try XCTUnwrap(expectedFrames(index: 1, transferred: false)[tokens[2]])
            let point = WindowMoveGeometry.targetFrame(in: frame, direction: .right).center
            XCTAssertEqual(WindowMoveGeometry.insertionDirection(at: point, in: frame), .right)
            return point
        }

        func report(_ frame: CGRect) {
            handler.nativeWindowFrameProvider = { _ in frame }
            handler.nativeWindowFrameFallbackProvider = { _ in nil }
        }

        func pressPoint() throws -> CGPoint {
            let frame = try XCTUnwrap(expectedFrames(index: 0, transferred: false)[dragged])
            let depth = (NiriLayoutEngine.doubleClickEdgeInset + NiriLayoutEngine.doubleClickTitleBarDepth) / 2
            return CGPoint(x: frame.midX, y: frame.maxY - depth)
        }

        func begin() throws {
            handler.retireNativeTitleBarDragAtInputBoundary()
            handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            let frame = try XCTUnwrap(expectedFrames(index: 0, transferred: false)[dragged])
            let press = try pressPoint()
            let displacement = frame.width / 8
            XCTAssertGreaterThan(displacement, max(FrameTolerance.frameWrite, FrameTolerance.screenMatch))
            report(frame)
            XCTAssertFalse(handler.dispatchMouseDown(at: press, modifiers: [], windowIdUnderPointer: dragged.windowId))
            handler.dispatchMouseDragged(at: CGPoint(x: press.x + displacement, y: press.y))
            report(frame.offsetBy(dx: displacement, dy: 0))
            XCTAssertTrue(handler.handleNativeTitleBarDragFrameChanged(for: try XCTUnwrap(manager.entry(for: dragged))))
        }

        func move(to point: CGPoint) throws {
            let start = try XCTUnwrap(expectedFrames(index: 0, transferred: false)[dragged])
            let press = try pressPoint()
            report(start.offsetBy(dx: point.x - press.x, dy: point.y - press.y))
            handler.dispatchMouseDragged(at: point)
            completeLayout()
        }

        func release(at point: CGPoint, transferred: Bool = true) throws {
            handler.pressedMouseButtonsProvider = { 0 }
            handler.dispatchMouseUp(at: point)
            completeLayout()
            try completeNativeFrame(transferred: transferred)
        }

        func cancel(at point: CGPoint) throws {
            handler.handleInputSuppressionBegan()
            handler.pressedMouseButtonsProvider = { 0 }
            handler.dispatchMouseUp(at: point)
            completeLayout()
            try completeNativeFrame(transferred: false)
        }

        func completeNativeFrame(transferred: Bool) throws {
            let frame = try XCTUnwrap(expectedFrames(index: transferred ? 1 : 0, transferred: transferred)[dragged])
            let reference = try XCTUnwrap(manager.entry(for: dragged)?.axRef)
            report(frame)
            controller.axManager.confirmFrameWrite(for: dragged.windowId, frame: frame)
            handler.handleNativeTitleBarDragFrameApplySucceeded(AXFrameApplyResult(
                pid: dragged.pid, windowId: dragged.windowId, expectedWindow: reference,
                targetFrame: frame, currentFrameHint: frame,
                writeResult: AXFrameWriteResult(
                    observedFrame: frame, writeOrder: .sizeThenPosition,
                    sizeError: .success, positionError: .success, failureReason: nil
                )
            ))
            handler.retireNativeTitleBarDragAtInputBoundary()
            completeLayout()
        }

        func completeLayout() {
            manager.withBatchedLayoutBuild {
                controller.dwindleLayoutHandler.layoutWithDwindleEngine(activeWorkspaces: Set(base.workspaces))
            }
            let refresh = controller.layoutRefreshController
            if let pending = refresh.layoutState.pendingRefresh {
                let blocked = refresh.layoutState.activeRefresh
                refresh.layoutState.pendingRefresh = nil
                refresh.layoutState.activeRefresh = pending
                refresh.finishRefresh(pending, didComplete: true, generation: refresh.layoutState.refreshGeneration)
                refresh.layoutState.activeRefreshTask = refreshTask
                refresh.layoutState.activeRefresh = blocked
            }
            completeFocus()
        }

        func completeFocus() {
            guard let request = controller.intentLedger.activeManagedRequest else { return }
            XCTAssertTrue(manager.pendingManagedFocusMatches(
                token: request.token, workspaceId: request.workspaceId, requestId: request.requestId
            ))
            XCTAssertTrue(manager.confirmManagedFocus(
                request.token, in: request.workspaceId, activateWorkspaceOnMonitor: false, requestId: request.requestId
            ))
            XCTAssertNotNil(controller.intentLedger.confirmManagedRequest(
                token: request.token, source: .focusedWindowChanged
            ))
        }

        func focus(_ token: WindowToken, index: Int) {
            let workspace = base.workspaces[index]
            manager.withEngineMutationScope(in: workspace) {
                engine.setSelectedNode(engine.findNode(for: token, in: workspace), in: workspace)
            }
            _ = controller.focusWindow(token, raisesWindow: false)
            completeFocus()
            XCTAssertEqual(manager.selectedManagedToken, token)
            XCTAssertEqual(controller.activeWorkspace()?.id, workspace)
        }

        func command(_ command: HotkeyCommand) {
            focus(tokens[0], index: 0)
            XCTAssertEqual(controller.commandHandler.performCommand(command), .executed)
            completeLayout()
        }

        func assertLayout(transferred: Bool, file: StaticString = #filePath, line: UInt = #line) {
            let groups = transferred
                ? [[[tokens[0]]], [[tokens[2]], [dragged]]]
                : [[[tokens[0]], [dragged]], [[tokens[2]]]]
            for index in base.workspaces.indices {
                let workspace = base.workspaces[index]
                let root = engine.root(for: workspace)
                XCTAssertEqual(
                    root?.collectAllLeaves().compactMap { $0.tile?.members.map(\.token) }, groups[index],
                    file: file, line: line
                )
                XCTAssertEqual(
                    Set(manager.entries(in: workspace).map(\.token)), Set(groups[index].flatMap { $0 }),
                    file: file, line: line
                )
                XCTAssertEqual(
                    root?.splitOrientation, groups[index].count == 1 ? nil : .horizontal,
                    file: file, line: line
                )
                let ratio: CGFloat? = groups[index].count == 1 ? nil : (index == 0 ? sourceRatio : 1)
                XCTAssertEqual(root?.splitRatio, ratio, file: file, line: line)
                XCTAssertEqual(
                    engine.currentFrames(in: workspace), expectedFrames(index: index, transferred: transferred),
                    file: file, line: line
                )
                for token in groups[index].flatMap({ $0 }) {
                    XCTAssertEqual(manager.workspace(for: token), workspace, file: file, line: line)
                    XCTAssertNotNil(engine.findNode(for: token, in: workspace), file: file, line: line)
                    XCTAssertNil(engine.findNode(for: token, in: base.workspaces[1 - index]), file: file, line: line)
                }
            }
        }

        func assertHistory(index: Int, undo: Int, redo: Int, file: StaticString = #filePath, line: UInt = #line) {
            let counts = engine.layoutHistoryCounts(in: base.workspaces[index])
            XCTAssertEqual(counts.undo, undo, file: file, line: line)
            XCTAssertEqual(counts.redo, redo, file: file, line: line)
        }

        func finish() {
            refreshCompletion.finish()
            refreshTask.cancel()
            controller.hasStartedServices = false
            controller.layoutRefreshController.resetState()
        }
    }

    func makeLiveCrossDisplayFixture() throws -> LiveCrossDisplayFixture {
        let base = try makeNativeFixture(
            [.dwindle, .dwindle], orientations: [.horizontal, .horizontal],
            frames: [
                CGRect(x: 137, y: -241, width: 1512, height: 912),
                CGRect(x: 1649, y: 173, width: 1712, height: 1012)
            ]
        )
        base.controller.motionPolicy.animationsEnabled = false
        base.controller.settings.focus.followsWindowToMonitor = false
        let stays = addWindow(1, to: base.source, base)
        base.manager.withEngineMutationScope(in: base.source) {
            _ = base.dwindle.setPreselection(.right, in: base.source)
        }
        let moved = addWindow(2, to: base.source, base)
        let resident = addWindow(3, to: base.target, base)
        let (events, completion) = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            var iterator = events.makeAsyncIterator()
            _ = await iterator.next()
        }
        base.controller.layoutRefreshController.layoutState.activeRefreshTask = task
        base.controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout, reason: .layoutCommand, affectedWorkspaceIds: Set(base.workspaces)
        )
        let fixture = LiveCrossDisplayFixture(
            base: base, tokens: [stays, moved, resident], refreshTask: task, refreshCompletion: completion
        )
        base.manager.withEngineMutationScope(in: base.source) {
            base.dwindle.root(for: base.source)?.kind = .split(orientation: .horizontal, ratio: fixture.sourceRatio)
        }
        for token in fixture.tokens { base.manager.setCachedConstraints(.unconstrained, for: token) }
        fixture.completeLayout()
        fixture.focus(moved, index: 0)
        let frames = fixture.expectedFrames(index: 0, transferred: false)
            .merging(fixture.expectedFrames(index: 1, transferred: false)) { _, last in last }
        let tokens = fixture.tokens
        for (token, frame) in frames { base.controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame) }
        base.controller.axEventHandler.windowInfoProvider = { windowId in
            guard let token = tokens.first(where: { $0.windowId == Int(windowId) }),
                  let frame = frames[token] else { return nil }
            return WindowServerInfo(id: windowId, pid: token.pid, level: 0, frame: frame)
        }
        base.handler.titleBarHitProvider = { _, _ in TitleBarHit(role: "AXWindow") }
        base.handler.topmostWindowIdProvider = { _ in moved.windowId }
        base.controller.hasStartedServices = true
        addTeardownBlock { @MainActor in fixture.finish() }
        return fixture
    }

    func testNativeDwindleCrossingChangesMembershipWhileHeldAndRecordsOneUndoableRelease() throws {
        let fixture = try makeLiveCrossDisplayFixture()
        let point = try fixture.crossingPoint()
        fixture.assertLayout(transferred: false)
        try fixture.begin()
        XCTAssertEqual(fixture.engine.liveMoveWorkspaceId, fixture.base.source)

        try fixture.move(to: point)

        fixture.assertLayout(transferred: true)
        XCTAssertEqual(fixture.engine.liveMoveWorkspaceId, fixture.base.target)
        XCTAssertEqual(fixture.engine.liveMoveToken, fixture.dragged)
        XCTAssertTrue(fixture.controller.isInteractiveGestureActive)
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
        let sequence = fixture.manager.worldSeq
        fixture.handler.dispatchMouseDragged(at: point)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
        fixture.assertLayout(transferred: true)

        try fixture.release(at: point)

        fixture.assertLayout(transferred: true)
        XCTAssertNil(fixture.engine.liveMoveWorkspaceId)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertFalse(fixture.controller.isInteractiveGestureActive)
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 1, redo: 0) }
        fixture.command(.sizing(.undo))
        fixture.assertLayout(transferred: false)
        fixture.assertHistory(index: 0, undo: 0, redo: 1)
        fixture.command(.sizing(.redo))
        fixture.assertLayout(transferred: true)
        fixture.assertHistory(index: 0, undo: 1, redo: 0)
    }

    func testCancellingNativeDwindleCrossingReturnsHomeWithoutHistory() throws {
        let fixture = try makeLiveCrossDisplayFixture()
        let point = try fixture.crossingPoint()
        try fixture.begin()
        try fixture.move(to: point)
        fixture.assertLayout(transferred: true)
        XCTAssertEqual(fixture.engine.liveMoveWorkspaceId, fixture.base.target)

        try fixture.cancel(at: point)

        fixture.assertLayout(transferred: false)
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
        XCTAssertNil(fixture.engine.liveMoveWorkspaceId)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertFalse(fixture.controller.isInteractiveGestureActive)
    }
}
