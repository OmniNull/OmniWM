// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

extension CrossDisplayDragTests {
    @MainActor
    struct MixedLiveCrossDisplayFixture {
        let common: LiveCrossDisplayFixture
        let niriOrientation: Monitor.Orientation

        var base: Fixture {
            common.base
        }

        var controller: WMController {
            common.controller
        }

        var manager: WorkspaceManager {
            common.manager
        }

        var handler: MouseEventHandler {
            common.handler
        }

        var tokens: [WindowToken] {
            common.tokens
        }

        var dragged: WindowToken {
            common.dragged
        }

        func completeLayout() {
            manager.withBatchedLayoutBuild {
                controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: Set(base.workspaces))
            }
            common.completeLayout()
        }

        func focus(_ token: WindowToken, index: Int) {
            let workspace = base.workspaces[index]
            if manager.activeLayoutKind(for: workspace) == .niri {
                manager.withNiriViewportState(for: workspace) {
                    $0.selectedNodeId = base.niri.findNode(for: token, in: workspace)?.id
                }
            } else {
                manager.withEngineMutationScope(in: workspace) {
                    base.dwindle.setSelectedNode(base.dwindle.findNode(for: token, in: workspace), in: workspace)
                }
            }
            _ = controller.focusWindow(token, raisesWindow: false)
            common.completeFocus()
            XCTAssertEqual(manager.selectedManagedToken, token)
            XCTAssertEqual(controller.activeWorkspace()?.id, workspace)
        }

        func begin() throws -> (frame: CGRect, press: CGPoint) {
            focus(dragged, index: 0)
            completeLayout()
            let frame = try XCTUnwrap(base.frame(dragged))
            controller.axManager.confirmFrameWrite(for: dragged.windowId, frame: frame)
            handler.retireNativeTitleBarDragAtInputBoundary()
            handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            common.report(frame)
            let depth = (NiriLayoutEngine.doubleClickEdgeInset + NiriLayoutEngine.doubleClickTitleBarDepth) / 2
            let press = CGPoint(x: frame.midX, y: frame.maxY - depth)
            let displacement = frame.width / 8
            XCTAssertGreaterThan(displacement, max(FrameTolerance.frameWrite, FrameTolerance.screenMatch))
            XCTAssertFalse(handler.dispatchMouseDown(at: press, modifiers: [], windowIdUnderPointer: dragged.windowId))
            handler.dispatchMouseDragged(at: CGPoint(x: press.x + displacement, y: press.y))
            common.report(frame.offsetBy(dx: displacement, dy: 0))
            XCTAssertTrue(handler.handleNativeTitleBarDragFrameChanged(for: try XCTUnwrap(manager.entry(for: dragged))))
            return (frame, press)
        }

        func pointBeside(_ token: WindowToken, index: Int) throws -> CGPoint {
            let frame = try XCTUnwrap(base.frame(token))
            let vertical = manager.activeLayoutKind(for: base.workspaces[index]) == .niri
                && controller.settings.monitors.effectiveOrientation(for: base.monitors[index]) == .vertical
            let direction: Direction = vertical ? .up : .right
            let point = WindowMoveGeometry.targetFrame(in: frame, direction: direction).center
            XCTAssertEqual(WindowMoveGeometry.insertionDirection(at: point, in: frame), direction)
            return point
        }

        func move(to point: CGPoint, from start: (frame: CGRect, press: CGPoint)) {
            common.report(start.frame.offsetBy(dx: point.x - start.press.x, dy: point.y - start.press.y))
            handler.dispatchMouseDragged(at: point)
            completeLayout()
        }

        func release(at point: CGPoint) throws {
            handler.pressedMouseButtonsProvider = { 0 }
            handler.dispatchMouseUp(at: point)
            handler.finishPendingLiveStackDrop()
            completeLayout()
            try completeNativeFrame()
        }

        func cancel(at point: CGPoint) throws {
            handler.handleInputSuppressionBegan()
            handler.pressedMouseButtonsProvider = { 0 }
            handler.dispatchMouseUp(at: point)
            completeLayout()
            if manager.entry(for: dragged) != nil { try completeNativeFrame() }
        }

        func completeNativeFrame() throws {
            let frame = try XCTUnwrap(base.frame(dragged))
            let reference = try XCTUnwrap(manager.entry(for: dragged)?.axRef)
            common.report(frame)
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

        func command(_ command: HotkeyCommand, token: WindowToken, index: Int) {
            focus(token, index: index)
            XCTAssertEqual(controller.commandHandler.performCommand(command), .executed)
            completeLayout()
        }

        func assertGroups(_ groups: [[WindowToken]], index: Int, file: StaticString = #filePath, line: UInt = #line) {
            let workspace = base.workspaces[index]
            let actual: [[WindowToken]]
            if manager.activeLayoutKind(for: workspace) == .niri {
                actual = base.niri.columns(in: workspace).compactMap {
                    $0.windowNodes.isEmpty ? nil : $0.windowNodes.map(\.token)
                }
            } else {
                actual = base.dwindle.root(for: workspace)?.collectAllLeaves()
                    .compactMap { $0.tile?.members.map(\.token) } ?? []
            }
            XCTAssertEqual(actual, groups, file: file, line: line)
            XCTAssertEqual(
                Set(manager.entries(in: workspace).map(\.token)), Set(groups.flatMap { $0 }), file: file, line: line
            )
            for token in groups.flatMap({ $0 }) {
                XCTAssertEqual(manager.workspace(for: token), workspace, file: file, line: line)
                if manager.activeLayoutKind(for: workspace) == .niri {
                    XCTAssertNotNil(base.niri.findNode(for: token, in: workspace), file: file, line: line)
                    XCTAssertNil(base.dwindle.findNode(for: token, in: workspace), file: file, line: line)
                } else {
                    XCTAssertNotNil(base.dwindle.findNode(for: token, in: workspace), file: file, line: line)
                    XCTAssertNil(base.niri.findNode(for: token, in: workspace), file: file, line: line)
                }
            }
        }

        func assertHistory(index: Int, undo: Int, redo: Int, file: StaticString = #filePath, line: UInt = #line) {
            let workspace = base.workspaces[index]
            if manager.activeLayoutKind(for: workspace) == .niri {
                XCTAssertEqual(
                    base.niri.states[workspace]?.layoutHistory.undoSnapshots.count ?? 0,
                    undo,
                    file: file,
                    line: line
                )
                XCTAssertEqual(
                    base.niri.states[workspace]?.layoutHistory.redoSnapshots.count ?? 0,
                    redo,
                    file: file,
                    line: line
                )
            } else {
                let counts = base.dwindle.layoutHistoryCounts(in: workspace)
                XCTAssertEqual(counts.undo, undo, file: file, line: line)
                XCTAssertEqual(counts.redo, redo, file: file, line: line)
            }
        }

        func clearHistory() {
            for workspace in base.workspaces {
                base.niri.clearLayoutHistory(in: workspace)
                base.dwindle.clearLayoutHistory(in: workspace)
            }
        }

        func assertDriver(index: Int, file: StaticString = #filePath, line: UInt = #line) {
            let workspace = base.workspaces[index]
            if manager.activeLayoutKind(for: workspace) == .niri {
                XCTAssertEqual(base.niri.liveColumnMove?.workspaceId, workspace, file: file, line: line)
                XCTAssertEqual(base.niri.liveColumnMove?.windowToken, dragged, file: file, line: line)
                XCTAssertNil(base.dwindle.liveMoveWorkspaceId, file: file, line: line)
            } else {
                XCTAssertEqual(base.dwindle.liveMoveWorkspaceId, workspace, file: file, line: line)
                XCTAssertEqual(base.dwindle.liveMoveToken, dragged, file: file, line: line)
                XCTAssertNil(base.niri.liveColumnMove, file: file, line: line)
            }
            XCTAssertTrue(controller.isInteractiveGestureActive, file: file, line: line)
        }

        func assertTerminal(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNil(base.niri.liveColumnMove, file: file, line: line)
            XCTAssertNil(base.dwindle.liveMoveWorkspaceId, file: file, line: line)
            XCTAssertNil(handler.state.nativeTitleBarDrag, file: file, line: line)
            XCTAssertFalse(controller.isInteractiveGestureActive, file: file, line: line)
        }
    }

    func makeMixedLiveCrossDisplayFixture(
        sourceNiri: Bool, orientation: Monitor.Orientation,
        emptyTarget: Bool = false, thirdLayout: LayoutType? = nil
    ) throws -> MixedLiveCrossDisplayFixture {
        let layouts: [LayoutType] = (sourceNiri ? [.niri, .dwindle] : [.dwindle, .niri])
            + (thirdLayout.map { [$0] } ?? [])
        let orientations = layouts.map { $0 == .niri ? orientation : .horizontal }
        let base = try makeNativeFixture(
            layouts, orientations: orientations,
            frames: [
                CGRect(x: 137, y: -241, width: orientations[0] == .vertical ? 912 : 1512, height: 1512),
                CGRect(x: 1649, y: 173, width: orientations[1] == .vertical ? 1012 : 1712, height: 1712),
                CGRect(x: 3361, y: 173, width: 1512, height: 1012)
            ]
        )
        base.controller.motionPolicy.animationsEnabled = false
        base.controller.settings.focus.followsWindowToMonitor = false
        base.controller.settings.niri.defaultContainerPrimarySpan = 1 / 4
        base.controller.settings.niri.centerFocusedColumn = .never
        base.controller.settings.niri.alwaysCenterSingleColumn = false
        base.controller.settings.niri.keepExistingWindowWidth = false
        base.controller.settings.niri.opensNewWindowsAtAppWidth = false
        base.controller.niriLayoutHandler.syncMonitorsToNiriEngine()
        let stays = addWindow(1, to: base.source, base)
        if !sourceNiri {
            base.manager.withEngineMutationScope(in: base.source) {
                _ = base.dwindle.setPreselection(.right, in: base.source)
            }
        }
        let moved = addWindow(2, to: base.source, base)
        let resident = emptyTarget ? WindowToken(pid: moved.pid, windowId: 3) : addWindow(3, to: base.target, base)
        for token in [stays, moved, resident] where base.manager.entry(for: token) != nil {
            base.manager.setCachedConstraints(.unconstrained, for: token)
        }
        let (events, completion) = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            var iterator = events.makeAsyncIterator()
            _ = await iterator.next()
        }
        base.controller.layoutRefreshController.layoutState.activeRefreshTask = task
        base.controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout, reason: .layoutCommand, affectedWorkspaceIds: Set(base.workspaces)
        )
        let common = LiveCrossDisplayFixture(
            base: base, tokens: [stays, moved, resident], refreshTask: task, refreshCompletion: completion
        )
        let fixture = MixedLiveCrossDisplayFixture(common: common, niriOrientation: orientation)
        fixture.completeLayout()
        fixture.focus(moved, index: 0)
        base.handler.titleBarHitProvider = { _, _ in TitleBarHit(role: "AXWindow") }
        base.handler.topmostWindowIdProvider = { _ in moved.windowId }
        base.controller.hasStartedServices = true
        addTeardownBlock { @MainActor in common.finish() }
        return fixture
    }

    func assertMixedNativeCrossingRelease(sourceNiri: Bool, orientation: Monitor.Orientation) throws {
        let fixture = try makeMixedLiveCrossDisplayFixture(sourceNiri: sourceNiri, orientation: orientation)
        let point = try fixture.pointBeside(fixture.tokens[2], index: 1)
        let start = try fixture.begin()
        fixture.move(to: point, from: start)
        fixture.assertGroups([[fixture.tokens[0]]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]], [fixture.dragged]], index: 1)
        fixture.assertDriver(index: 1)
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
        try fixture.release(at: point)
        fixture.assertGroups([[fixture.tokens[0]]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]], [fixture.dragged]], index: 1)
        fixture.assertTerminal()
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 1, redo: 0) }
        fixture.command(.sizing(.undo), token: fixture.tokens[0], index: 0)
        fixture.assertGroups([[fixture.tokens[0]], [fixture.dragged]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]]], index: 1)
        fixture.assertHistory(index: 0, undo: 0, redo: 1)
        fixture.command(.sizing(.redo), token: fixture.tokens[0], index: 0)
        fixture.assertGroups([[fixture.tokens[0]]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]], [fixture.dragged]], index: 1)
        fixture.assertHistory(index: 0, undo: 1, redo: 0)
    }

    func testNativeDwindleToHorizontalNiriCrossingRemainsLiveAndUndoable() throws {
        try assertMixedNativeCrossingRelease(sourceNiri: false, orientation: .horizontal)
    }

    func testNativeDwindleToVerticalNiriCrossingRemainsLiveAndUndoable() throws {
        try assertMixedNativeCrossingRelease(sourceNiri: false, orientation: .vertical)
    }

    func testNativeHorizontalNiriToDwindleCrossingRemainsLiveAndUndoable() throws {
        try assertMixedNativeCrossingRelease(sourceNiri: true, orientation: .horizontal)
    }

    func testNativeVerticalNiriToDwindleCrossingRemainsLiveAndUndoable() throws {
        try assertMixedNativeCrossingRelease(sourceNiri: true, orientation: .vertical)
    }

    func testSuppressingMixedNativeCrossingsRestoresBothLayoutsWithoutHistory() throws {
        for sourceNiri in [false, true] {
            let fixture = try makeMixedLiveCrossDisplayFixture(sourceNiri: sourceNiri, orientation: .vertical)
            let point = try fixture.pointBeside(fixture.tokens[2], index: 1)
            let start = try fixture.begin()
            fixture.move(to: point, from: start)
            fixture.assertGroups([[fixture.tokens[0]]], index: 0)
            fixture.assertDriver(index: 1)
            try fixture.cancel(at: point)
            fixture.assertGroups([[fixture.tokens[0]], [fixture.dragged]], index: 0)
            fixture.assertGroups([[fixture.tokens[2]]], index: 1)
            for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
            fixture.assertTerminal()
        }
    }

    func testWholeTabbedNiriColumnCrossesIntoDwindleAsOneGroupAndCancelsHome() throws {
        let fixture = try makeMixedLiveCrossDisplayFixture(sourceNiri: true, orientation: .vertical)
        let peer = addWindow(4, to: fixture.base.source, fixture.base)
        try stack(fixture.dragged, onto: peer, in: fixture.base.source, fixture.base)
        let column = try XCTUnwrap(fixture.base.niri.columns(in: fixture.base.source).last)
        fixture.manager.withEngineMutationScope(in: fixture.base.source) {
            XCTAssertTrue(fixture.base.niri.setColumnDisplay(
                .tabbed, for: column, in: fixture.base.source, motion: fixture.controller.motionPolicy.snapshot(),
                orientation: .vertical, gaps: fixture.controller.innerGap(for: fixture.base.monitors[0])
            ))
        }
        fixture.completeLayout()
        fixture.clearHistory()
        fixture.assertGroups([[fixture.tokens[0]], [peer, fixture.dragged]], index: 0)
        let point = try XCTUnwrap(fixture.base.frame(fixture.tokens[2])).center
        let start = try fixture.begin()
        fixture.move(to: point, from: start)
        fixture.assertGroups([[fixture.tokens[0]]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]], [fixture.dragged, peer]], index: 1)
        XCTAssertEqual(
            fixture.base.dwindle.tile(containing: fixture.dragged, in: fixture.base.target)?.activeToken,
            fixture.dragged
        )
        try fixture.cancel(at: point)
        fixture.assertGroups([[fixture.tokens[0]], [peer, fixture.dragged]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]]], index: 1)
        XCTAssertEqual(fixture.base.niri.columns(in: fixture.base.source).last?.displayMode, .tabbed)
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
    }

    func testDwindleNativeCrossingHonorsMemberAndWholeGroupSettings() throws {
        for wholeGroup in [false, true] {
            let fixture = try makeMixedLiveCrossDisplayFixture(sourceNiri: false, orientation: .horizontal)
            let peer = addWindow(4, to: fixture.base.source, fixture.base)
            fixture.manager.withEngineMutationScope(in: fixture.base.source) {
                XCTAssertTrue(fixture.base.dwindle.groupWindow(fixture.dragged, into: peer, in: fixture.base.source))
            }
            fixture.controller.settings.gestures.dwindleGroupDragAcrossDisplays = wholeGroup ? .group : .window
            fixture.completeLayout()
            let point = try fixture.pointBeside(fixture.tokens[2], index: 1)
            let start = try fixture.begin()
            fixture.move(to: point, from: start)
            let remaining = wholeGroup ? [[fixture.tokens[0]]] : [[fixture.tokens[0]], [peer]]
            let arriving = wholeGroup ? [fixture.dragged, peer] : [fixture.dragged]
            fixture.assertGroups(remaining, index: 0)
            fixture.assertGroups([[fixture.tokens[2]], arriving], index: 1)
            let finishPoint: CGPoint
            if wholeGroup {
                finishPoint = try fixture.pointBeside(fixture.tokens[0], index: 0)
                fixture.move(to: finishPoint, from: start)
                fixture.assertGroups([[fixture.tokens[0]], [peer, fixture.dragged]], index: 0)
                fixture.assertGroups([[fixture.tokens[2]]], index: 1)
                XCTAssertEqual(
                    fixture.base.dwindle.tile(containing: fixture.dragged, in: fixture.base.source)?.activeToken,
                    fixture.dragged
                )
                fixture.assertDriver(index: 0)
            } else {
                finishPoint = point
            }
            try fixture.cancel(at: finishPoint)
            fixture.assertGroups([[fixture.tokens[0]], [peer, fixture.dragged]], index: 0)
            fixture.assertGroups([[fixture.tokens[2]]], index: 1)
            for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
        }
    }

    func testNativeMixedCrossingCanEnterAnEmptyDestinationAndCancel() throws {
        for sourceNiri in [false, true] {
            let fixture = try makeMixedLiveCrossDisplayFixture(
                sourceNiri: sourceNiri, orientation: .vertical, emptyTarget: true
            )
            let point = fixture.controller.insetWorkingFrame(for: fixture.base.monitors[1]).center
            let start = try fixture.begin()
            fixture.move(to: point, from: start)
            fixture.assertGroups([[fixture.tokens[0]]], index: 0)
            fixture.assertGroups([[fixture.dragged]], index: 1)
            fixture.assertDriver(index: 1)
            try fixture.cancel(at: point)
            fixture.assertGroups([[fixture.tokens[0]], [fixture.dragged]], index: 0)
            fixture.assertGroups([], index: 1)
            for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
        }
    }

    func testNativeCrossingCanReturnHomeAndThenVisitAThirdDisplayBeforeCancellation() throws {
        let fixture = try makeMixedLiveCrossDisplayFixture(
            sourceNiri: false, orientation: .vertical, thirdLayout: .dwindle
        )
        let third = addWindow(4, to: fixture.base.workspaces[2], fixture.base)
        fixture.completeLayout()
        let start = try fixture.begin()
        let targetPoint = try fixture.pointBeside(fixture.tokens[2], index: 1)
        fixture.move(to: targetPoint, from: start)
        fixture.assertDriver(index: 1)
        let home = try fixture.pointBeside(fixture.tokens[0], index: 0)
        fixture.move(to: home, from: start)
        fixture.assertGroups([[fixture.tokens[0]], [fixture.dragged]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]]], index: 1)
        fixture.assertDriver(index: 0)
        let finalPoint = try fixture.pointBeside(third, index: 2)
        fixture.move(to: finalPoint, from: start)
        fixture.assertGroups([[fixture.tokens[0]]], index: 0)
        fixture.assertGroups([[third], [fixture.dragged]], index: 2)
        fixture.assertDriver(index: 2)
        try fixture.cancel(at: finalPoint)
        fixture.assertGroups([[fixture.tokens[0]], [fixture.dragged]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]]], index: 1)
        fixture.assertGroups([[third]], index: 2)
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
        fixture.assertTerminal()
    }

    func testNativeLiveCrossingRefusesAFullscreenDwindleDestination() throws {
        let fixture = try makeMixedLiveCrossDisplayFixture(sourceNiri: true, orientation: .horizontal)
        fixture.manager.withEngineMutationScope(in: fixture.base.target) {
            XCTAssertEqual(fixture.base.dwindle.toggleFullscreen(in: fixture.base.target), fixture.tokens[2])
        }
        fixture.completeLayout()
        let start = try fixture.begin()
        let point = fixture.controller.insetWorkingFrame(for: fixture.base.monitors[1]).center
        let sequence = fixture.manager.worldSeq
        fixture.common.report(start.frame.offsetBy(dx: point.x - start.press.x, dy: point.y - start.press.y))
        fixture.handler.dispatchMouseDragged(at: point)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
        fixture.assertGroups([[fixture.tokens[0]], [fixture.dragged]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]]], index: 1)
        fixture.assertDriver(index: 0)
        try fixture.cancel(at: point)
        XCTAssertEqual(fixture.base.dwindle.fullscreenTokens(in: fixture.base.target), [fixture.tokens[2]])
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
    }

    func testHidingTheCurrentDwindleDestinationCancelsTheOwnedCrossingBeforeRelease() throws {
        let fixture = try makeMixedLiveCrossDisplayFixture(sourceNiri: true, orientation: .horizontal)
        let point = try fixture.pointBeside(fixture.tokens[2], index: 1)
        let start = try fixture.begin()
        fixture.move(to: point, from: start)
        fixture.assertDriver(index: 1)
        let replacement = try XCTUnwrap(fixture.manager.createDynamicWorkspace(
            named: "\(fixture.base.workspaces.count + 1)", on: fixture.base.monitors[1].id
        ))
        fixture.manager.updateWorkspace(replacement.id) {
            $0.runtimeMonitorOverride = OutputId(from: fixture.base.monitors[1])
        }
        XCTAssertTrue(fixture.manager.setActiveWorkspace(replacement.id, on: fixture.base.monitors[1].id))

        fixture.handler.dispatchMouseDragged(at: point)

        XCTAssertTrue(fixture.handler.liveCrossDisplayMove == nil)
        XCTAssertNil(fixture.base.dwindle.liveMoveWorkspaceId)
        fixture.completeLayout()
        fixture.assertGroups([[fixture.tokens[0]], [fixture.dragged]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]]], index: 1)
        XCTAssertEqual(fixture.manager.entries(in: replacement.id).map(\.token), [])
        try fixture.release(at: point)
        fixture.assertGroups([[fixture.tokens[0]], [fixture.dragged]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]]], index: 1)
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
        fixture.assertTerminal()
    }

    func testExistingNiriCarryThenDwindleCrossingCancelsToTheOriginalNiriWorkspace() throws {
        let fixture = try makeMixedLiveCrossDisplayFixture(
            sourceNiri: true, orientation: .horizontal, thirdLayout: .niri
        )
        let third = addWindow(4, to: fixture.base.workspaces[2], fixture.base)
        fixture.completeLayout()
        let start = try fixture.begin()
        let niriPoint = try fixture.pointBeside(third, index: 2)
        fixture.move(to: niriPoint, from: start)
        fixture.assertGroups([[fixture.tokens[0]]], index: 0)
        fixture.assertGroups([[third], [fixture.dragged]], index: 2)
        fixture.assertDriver(index: 2)
        XCTAssertTrue(fixture.handler.liveCrossDisplayMove == nil)
        XCTAssertEqual(fixture.base.niri.liveColumnMove?.carry?.originalWorkspaceId, fixture.base.source)

        let dwindlePoint = try fixture.pointBeside(fixture.tokens[2], index: 1)
        fixture.move(to: dwindlePoint, from: start)

        fixture.assertGroups([[fixture.tokens[0]]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]], [fixture.dragged]], index: 1)
        fixture.assertGroups([[third]], index: 2)
        fixture.assertDriver(index: 1)
        XCTAssertEqual(fixture.handler.liveCrossDisplayMove?.originWorkspaceId, fixture.base.source)
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
        try fixture.cancel(at: dwindlePoint)
        fixture.assertGroups([[fixture.tokens[0]], [fixture.dragged]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]]], index: 1)
        fixture.assertGroups([[third]], index: 2)
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
        fixture.assertTerminal()
    }

    func testClosingTheCarriedWindowDoesNotResurrectItOnCancellation() throws {
        let fixture = try makeMixedLiveCrossDisplayFixture(sourceNiri: false, orientation: .horizontal)
        let point = try fixture.pointBeside(fixture.tokens[2], index: 1)
        let start = try fixture.begin()
        fixture.move(to: point, from: start)
        fixture.assertGroups([[fixture.tokens[0]]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]], [fixture.dragged]], index: 1)
        XCTAssertNotNil(fixture.manager.removeWindow(pid: fixture.dragged.pid, windowId: fixture.dragged.windowId))
        fixture.completeLayout()
        try fixture.cancel(at: point)
        fixture.assertGroups([[fixture.tokens[0]]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]]], index: 1)
        XCTAssertNil(fixture.manager.entry(for: fixture.dragged))
        for workspace in fixture.base.workspaces {
            XCTAssertNil(fixture.base.niri.findNode(for: fixture.dragged, in: workspace))
            XCTAssertNil(fixture.base.dwindle.findNode(for: fixture.dragged, in: workspace))
        }
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
        fixture.assertTerminal()
    }
}

extension CrossDisplayDragTests {
    func testLoneNiriWindowStartsLiveCarryToDwindleAndCancelsHome() throws {
        let fixture = try makeMixedLiveCrossDisplayFixture(sourceNiri: true, orientation: .horizontal)
        let removed = fixture.tokens[0]
        XCTAssertNotNil(fixture.manager.removeWindow(pid: removed.pid, windowId: removed.windowId))
        fixture.completeLayout()
        fixture.assertGroups([[fixture.dragged]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]]], index: 1)
        let point = try fixture.pointBeside(fixture.tokens[2], index: 1)
        let start = try fixture.begin()
        fixture.assertDriver(index: 0)

        fixture.move(to: point, from: start)

        fixture.assertGroups([], index: 0)
        fixture.assertGroups([[fixture.tokens[2]], [fixture.dragged]], index: 1)
        fixture.assertDriver(index: 1)
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
        try fixture.cancel(at: point)
        fixture.assertGroups([[fixture.dragged]], index: 0)
        fixture.assertGroups([[fixture.tokens[2]]], index: 1)
        XCTAssertNil(fixture.manager.entry(for: removed))
        for index in fixture.base.workspaces.indices { fixture.assertHistory(index: index, undo: 0, redo: 0) }
        fixture.assertTerminal()
    }
}
