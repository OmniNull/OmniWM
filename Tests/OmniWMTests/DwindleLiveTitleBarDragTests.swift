// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class DwindleLiveTitleBarDragTests: NiriInteractionTestCase {
    struct RefreshBlocker {
        let task: Task<Void, Never>
        let completion: AsyncStream<Void>.Continuation
    }

    @MainActor
    struct Fixture {
        let controller: WMController
        let engine: DwindleLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let horizontal: Bool
        let tokens: [WindowToken]
        let blocker: RefreshBlocker

        var manager: WorkspaceManager {
            controller.workspaceManager
        }

        var handler: MouseEventHandler {
            controller.mouseEventHandler
        }

        var dragged: WindowToken {
            tokens[1]
        }

        var neighbor: WindowToken {
            tokens[2]
        }

        func order() -> [[WindowToken]] {
            engine.root(for: workspaceId)?.collectAllLeaves().compactMap { $0.tile?.members.map(\.token) } ?? []
        }

        func expectedFrames(swapped: Bool) -> [WindowToken: CGRect] {
            let area = controller.insetWorkingFrame(for: monitor)
            let split = horizontal ? area.width / 2 : area.height / 2
            var frames: [WindowToken: CGRect] = [:]
            for index in 0 ..< 2 {
                let group = (index == 0) != swapped
                let raw = horizontal
                    ? CGRect(x: area.minX + CGFloat(index) * split, y: area.minY, width: split, height: area.height)
                    : CGRect(x: area.minX, y: area.minY + CGFloat(index) * split, width: area.width, height: split)
                var frame = DwindleGapCalculator.applyGaps(nodeRect: raw, tilingArea: area, settings: engine.settings)
                if group {
                    let rail = min(controller.tabRailStyle.reservedWidth, frame.width)
                    frame.origin.x += rail
                    frame.size.width -= rail
                }
                frames[group ? dragged : neighbor] = frame
            }
            return frames
        }

        func report(_ frame: CGRect) {
            handler.nativeWindowFrameProvider = { _ in frame }
            handler.nativeWindowFrameFallbackProvider = { _ in nil }
        }

        func begin(swapped: Bool = false) throws {
            handler.retireNativeTitleBarDragAtInputBoundary()
            handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            let start = try XCTUnwrap(expectedFrames(swapped: swapped)[dragged])
            report(start)
            let depth = (NiriLayoutEngine.doubleClickEdgeInset + NiriLayoutEngine.doubleClickTitleBarDepth) / 2
            let press = CGPoint(x: start.midX, y: start.maxY - depth)
            let displacement = CGPoint(x: start.width / 8, y: 0)
            XCTAssertGreaterThan(displacement.x, max(FrameTolerance.frameWrite, FrameTolerance.screenMatch))
            XCTAssertFalse(handler.dispatchMouseDown(
                at: press, modifiers: [], windowIdUnderPointer: dragged.windowId
            ))
            handler.dispatchMouseDragged(at: CGPoint(x: press.x + displacement.x, y: press.y))
            report(start.offsetBy(dx: displacement.x, dy: displacement.y))
            XCTAssertTrue(handler.handleNativeTitleBarDragFrameChanged(for: try XCTUnwrap(manager.entry(for: dragged))))
        }

        func move(to point: CGPoint) {
            handler.dispatchMouseDragged(at: point)
            completeLayout()
        }

        func release(at point: CGPoint, swapped: Bool) throws {
            handler.pressedMouseButtonsProvider = { 0 }
            handler.dispatchMouseUp(at: point)
            completeLayout()
            try completeNativeFrame(swapped: swapped)
        }

        func cancel(at point: CGPoint) throws {
            handler.cancelActiveMouseInteraction()
            handler.pressedMouseButtonsProvider = { 0 }
            handler.dispatchMouseUp(at: point)
            completeLayout()
            try completeNativeFrame(swapped: false)
        }

        func completeNativeFrame(swapped: Bool) throws {
            let frame = try XCTUnwrap(expectedFrames(swapped: swapped)[dragged])
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
                controller.dwindleLayoutHandler.layoutWithDwindleEngine(activeWorkspaces: [workspaceId])
            }
            let refresh = controller.layoutRefreshController
            if let pending = refresh.layoutState.pendingRefresh {
                let blocked = refresh.layoutState.activeRefresh
                refresh.layoutState.pendingRefresh = nil
                refresh.layoutState.activeRefresh = pending
                refresh.finishRefresh(pending, didComplete: true, generation: refresh.layoutState.refreshGeneration)
                refresh.layoutState.activeRefreshTask = blocker.task
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

        func focus() {
            manager.withEngineMutationScope(in: workspaceId) {
                engine.setSelectedNode(engine.findNode(for: dragged, in: workspaceId), in: workspaceId)
            }
            _ = controller.focusWindow(dragged, raisesWindow: false)
            completeFocus()
        }

        func command(_ command: HotkeyCommand) {
            focus()
            XCTAssertEqual(controller.commandHandler.performCommand(command), .executed)
            completeLayout()
        }

        func assertLayout(swapped: Bool, file: StaticString = #filePath, line: UInt = #line) {
            let group = [tokens[0], dragged]
            XCTAssertEqual(order(), swapped ? [[neighbor], group] : [group, [neighbor]], file: file, line: line)
            XCTAssertEqual(
                engine.currentFrames(in: workspaceId),
                expectedFrames(swapped: swapped),
                file: file,
                line: line
            )
            XCTAssertEqual(
                engine.tile(containing: dragged, in: workspaceId)?.activeToken,
                dragged,
                file: file,
                line: line
            )
            XCTAssertEqual(engine.root(for: workspaceId)?.splitRatio, 1, file: file, line: line)
            XCTAssertEqual(
                engine.root(for: workspaceId)?.splitOrientation,
                horizontal ? .horizontal : .vertical,
                file: file,
                line: line
            )
            XCTAssertEqual(Set(manager.entries(in: workspaceId).map(\.token)), Set(tokens), file: file, line: line)
            for token in tokens { XCTAssertEqual(manager.workspace(for: token), workspaceId, file: file, line: line) }
        }

        func assertHistory(undo: Int, redo: Int, file: StaticString = #filePath, line: UInt = #line) {
            let counts = engine.layoutHistoryCounts(in: workspaceId)
            XCTAssertEqual(counts.undo, undo, file: file, line: line)
            XCTAssertEqual(counts.redo, redo, file: file, line: line)
        }

        func finish() {
            blocker.completion.finish()
            blocker.task.cancel()
            controller.hasStartedServices = false
            controller.layoutRefreshController.resetState()
            handler.cleanup()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
        }
    }

    func makeFixture(horizontal: Bool = true) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "DwindleLiveTitleBarDragTests")
        controller.settings.animationsEnabled = false
        controller.motionPolicy.animationsEnabled = false
        let frame = CGRect(x: 137, y: -241, width: horizontal ? 1512 : 912, height: horizontal ? 912 : 1512)
        let monitor = Monitor(
            id: .init(displayId: 938_701), displayId: 938_701, frame: frame,
            visibleFrame: frame, hasNotch: false, name: "Dwindle native live movement"
        )
        controller.settings.monitors.updateOrientationSettings(
            .init(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                orientation: horizontal ? .horizontal : .vertical
            ), for: monitor
        )
        controller.settings.workspaces.configurations = [
            .init(name: "1", monitorAssignment: .specificDisplay(OutputId(from: monitor)), layoutType: .dwindle)
        ]
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        manager.applySettings()
        let workspace = try XCTUnwrap(manager.workspaceId(named: "1"))
        XCTAssertTrue(manager.setActiveWorkspace(workspace, on: monitor.id, updateInteractionMonitor: true))
        controller.enableNiriLayout()
        controller.enableDwindleLayout()
        let engine = try XCTUnwrap(controller.dwindleEngine)
        let tokens = (1 ... 3).map { WindowToken(pid: 938_701, windowId: $0) }
        for token in tokens {
            _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: controller)
            manager.setCachedConstraints(.unconstrained, for: token)
        }
        manager.withEngineMutationScope(in: workspace) {
            controller.dwindleLayoutHandler.applyResolvedSettings(
                controller.resolvedDwindleSettings(for: monitor), to: engine
            )
            for token in tokens {
                _ = engine.setPreselection(horizontal ? .right : .up, in: workspace)
                _ = engine.addWindow(token: token, to: workspace, activeWindowFrame: nil)
            }
            XCTAssertTrue(engine.groupWindow(tokens[1], into: tokens[0], in: workspace))
        }
        controller.layoutRefreshController.resetState()
        let blocker = blockRefreshes(controller, workspace: workspace)
        let fixture = Fixture(
            controller: controller,
            engine: engine,
            workspaceId: workspace,
            monitor: monitor,
            horizontal: horizontal,
            tokens: tokens,
            blocker: blocker
        )
        fixture.completeLayout()
        fixture.focus()
        let frames = fixture.expectedFrames(swapped: false)
        for (token, frame) in frames { controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame) }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard let token = tokens.first(where: { $0.windowId == Int(windowId) }),
                  let frame = frames[token] else { return nil }
            return WindowServerInfo(id: windowId, pid: token.pid, level: 0, frame: frame)
        }
        fixture.handler.titleBarHitProvider = { _, _ in TitleBarHit(role: "AXWindow") }
        fixture.handler.topmostWindowIdProvider = { _ in tokens[1].windowId }
        controller.hasStartedServices = true
        addTeardownBlock { @MainActor in fixture.finish() }
        return fixture
    }

    func blockRefreshes(_ controller: WMController, workspace: WorkspaceDescriptor.ID) -> RefreshBlocker {
        let (events, completion) = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            var iterator = events.makeAsyncIterator()
            _ = await iterator.next()
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = task
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout, reason: .layoutCommand, affectedWorkspaceIds: [workspace]
        )
        return RefreshBlocker(task: task, completion: completion)
    }

    func testNativeGroupedTitleBarSwapIsLiveStableAndRecordsOneUndoableRelease() throws {
        let fixture = try makeFixture()
        fixture.assertLayout(swapped: false)
        fixture.assertHistory(undo: 0, redo: 0)
        let group = try XCTUnwrap(fixture.engine.tile(containing: fixture.dragged, in: fixture.workspaceId))
        let target = try XCTUnwrap(fixture.expectedFrames(swapped: false)[fixture.neighbor]).center
        try fixture.begin()
        XCTAssertTrue(fixture.handler.state.nativeTitleBarDrag?.dwindleLiveDrag == true)
        XCTAssertEqual(fixture.engine.liveMoveToken, fixture.dragged)
        XCTAssertEqual(fixture.engine.liveMoveWorkspaceId, fixture.workspaceId)
        fixture.move(to: target)
        fixture.assertLayout(swapped: true)
        XCTAssertTrue(fixture.engine.tile(containing: fixture.dragged, in: fixture.workspaceId) === group)
        fixture.assertHistory(undo: 0, redo: 0)
        let sequence = fixture.manager.worldSeq
        fixture.handler.dispatchMouseDragged(at: target)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
        fixture.assertLayout(swapped: true)

        try fixture.release(at: target, swapped: true)

        fixture.assertLayout(swapped: true)
        fixture.assertHistory(undo: 1, redo: 0)
        XCTAssertNil(fixture.engine.liveMoveToken)
        XCTAssertNil(fixture.engine.liveMoveWorkspaceId)
        XCTAssertNil(fixture.engine.interactiveMove)
        fixture.command(.sizing(.undo))
        fixture.assertLayout(swapped: false)
        fixture.assertHistory(undo: 0, redo: 1)
        fixture.command(.sizing(.redo))
        fixture.assertLayout(swapped: true)
        fixture.assertHistory(undo: 1, redo: 0)
    }

    func testCancellingNativeGroupedTitleBarSwapRestoresWithoutHistory() throws {
        let fixture = try makeFixture()
        fixture.assertLayout(swapped: false)
        let group = try XCTUnwrap(fixture.engine.tile(containing: fixture.dragged, in: fixture.workspaceId))
        let target = try XCTUnwrap(fixture.expectedFrames(swapped: false)[fixture.neighbor]).center
        try fixture.begin()
        fixture.move(to: target)
        fixture.assertLayout(swapped: true)
        fixture.assertHistory(undo: 0, redo: 0)

        try fixture.cancel(at: target)

        fixture.assertLayout(swapped: false)
        fixture.assertHistory(undo: 0, redo: 0)
        XCTAssertTrue(fixture.engine.tile(containing: fixture.dragged, in: fixture.workspaceId) === group)
        XCTAssertNil(fixture.engine.liveMoveWorkspaceId)
        XCTAssertNil(fixture.engine.liveMoveToken)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
    }

    func testConsecutiveNativeCancellationsKeepTheConfirmedBaselineForTheNextDrag() throws {
        let fixture = try makeFixture()
        let original = fixture.expectedFrames(swapped: false)
        let target = try XCTUnwrap(original[fixture.neighbor]).center
        let start = try XCTUnwrap(original[fixture.dragged])
        for _ in 0 ..< 2 {
            try fixture.begin()
            XCTAssertEqual(fixture.engine.liveMoveToken, fixture.dragged)
            XCTAssertTrue(fixture.handler.state.nativeTitleBarDrag?.dwindleLiveDrag == true)
            fixture.move(to: target)
            fixture.assertLayout(swapped: true)

            try fixture.cancel(at: target)

            fixture.assertLayout(swapped: false)
            fixture.assertHistory(undo: 0, redo: 0)
            XCTAssertNil(fixture.engine.liveMoveWorkspaceId)
            XCTAssertNil(fixture.engine.interactiveMove)
            XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: fixture.dragged))
            XCTAssertEqual(fixture.controller.axManager.lastAppliedFrame(for: fixture.dragged.windowId), start)
        }
    }
}
