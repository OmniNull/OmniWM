// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

extension CrossDisplayDragTests {
    func testNativeDwindleReorderBeforeCrossDisplayDropRecordsOnlyTheTransfer() throws {
        let (fixture, tokens) = try mixedHistoryMakeFixture(sourceNiri: false)
        let blocker = blockMixedHistoryRefreshes(fixture)
        defer { finishMixedHistoryRefreshes(fixture, blocker) }
        fixture.handler.titleBarHitProvider = { _, _ in TitleBarHit(role: "AXWindow") }
        mixedHistoryCompleteLayout(fixture)
        let moved = tokens[0]
        let neighbor = tokens[1]
        let localTarget = try XCTUnwrap(fixture.frame(neighbor)).center
        let start = try beginNativeDrag(moved, fixture)
        let offset = start.width / 8
        fixture.handler.dispatchMouseDragged(at: CGPoint(x: start.midX + offset, y: start.midY))
        fixture.handler.nativeWindowFrameProvider = { _ in start.offsetBy(dx: offset, dy: 0) }
        XCTAssertTrue(fixture.handler
            .handleNativeTitleBarDragFrameChanged(for: try XCTUnwrap(fixture.manager.entry(for: moved))))
        XCTAssertEqual(fixture.dwindle.liveMoveToken, moved)
        fixture.handler.dispatchMouseDragged(at: localTarget)
        mixedHistoryCompleteLayout(fixture)
        mixedHistoryAssertGroups(fixture, index: 0, groups: [[neighbor], [moved]])
        mixedHistoryAssertCounts(fixture, index: 0, undo: 0, redo: 0)
        let target = try XCTUnwrap(fixture.frame(tokens[2])).center
        fixture.handler.dispatchMouseDragged(at: target)
        let displacement = fixture.monitors[1].frame.minX - fixture.monitors[0].frame.minX
        fixture.handler.nativeWindowFrameProvider = { _ in start.offsetBy(dx: displacement, dy: 0) }

        fixture.handler.dispatchMouseUp(at: target)
        mixedHistoryCompleteLayout(fixture)

        XCTAssertEqual(fixture.manager.workspace(for: moved), fixture.target)
        XCTAssertNil(fixture.dwindle.liveMoveWorkspaceId)
        XCTAssertNil(fixture.dwindle.interactiveMove)
        mixedHistoryAssertCounts(fixture, index: 0, undo: 1, redo: 0)
        mixedHistoryFocus(neighbor, index: 0, fixture)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.sizing(.undo)), .executed)
        mixedHistoryCompleteLayout(fixture)
        mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [moved, neighbor], ratio: 1)
        mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2]])
        mixedHistoryAssertCounts(fixture, index: 0, undo: 0, redo: 1)
    }

    func testNiriToDwindleCommandTransferUndoRedoFromSourceRestoresDeclaredPlacement() throws {
        let (fixture, tokens) = try mixedHistoryMakeFixture(sourceNiri: true)
        let blocker = blockMixedHistoryRefreshes(fixture)
        defer { finishMixedHistoryRefreshes(fixture, blocker) }
        mixedHistoryCompleteLayout(fixture)
        mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0], tokens[1]])
        mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2]])
        mixedHistoryFocus(tokens[1], index: 0, fixture)
        XCTAssertEqual(fixture.manager.selectedManagedToken, tokens[1])
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.workspace(.moveTo(1))), .executed)
        mixedHistoryCompleteLayout(fixture)
        mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0]])
        mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2], tokens[1]], ratio: 1)

        mixedHistoryFocus(tokens[0], index: 0, fixture)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.sizing(.undo)), .executed)
        mixedHistoryCompleteLayout(fixture)

        mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0], tokens[1]])
        mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2]])
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.source)
        XCTAssertEqual(fixture.manager.selectedManagedToken, tokens[1])
        mixedHistoryFocus(tokens[0], index: 0, fixture)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.sizing(.redo)), .executed)
        mixedHistoryCompleteLayout(fixture)
        mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0]])
        mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2], tokens[1]], ratio: 1)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.target)
        XCTAssertEqual(fixture.manager.selectedManagedToken, tokens[1])
    }

    func testMixedTransferCommandsRecordOneEntryAndUndoRedoFromBothSides() throws {
        for sourceNiri in [true, false] {
            for historyIndex in [0, 1] {
                let (fixture, tokens) = try mixedHistoryMakeFixture(sourceNiri: sourceNiri)
                let blocker = blockMixedHistoryRefreshes(fixture)
                defer { finishMixedHistoryRefreshes(fixture, blocker) }
                mixedHistoryCompleteLayout(fixture)
                mixedHistoryFocus(tokens[1], index: 0, fixture)
                mixedHistoryCommand(.workspace(.moveTo(1)), fixture)
                mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0]])
                mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2], tokens[1]], ratio: 1)
                mixedHistoryAssertCounts(fixture, index: 0, undo: 1, redo: 0)
                mixedHistoryAssertCounts(fixture, index: 1, undo: 1, redo: 0)
                let resident = historyIndex == 0 ? tokens[0] : tokens[2]
                mixedHistoryFocus(resident, index: historyIndex, fixture)
                mixedHistoryCommand(.sizing(.undo), fixture)
                mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0], tokens[1]], ratio: 1)
                mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2]])
                mixedHistoryAssertCounts(fixture, index: historyIndex, undo: 0, redo: 1)
                mixedHistoryFocus(resident, index: historyIndex, fixture)
                mixedHistoryCommand(.sizing(.redo), fixture)
                mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0]])
                mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2], tokens[1]], ratio: 1)
                mixedHistoryAssertCounts(fixture, index: historyIndex, undo: 1, redo: 0)
            }
        }
    }

    func testMixedBarBatchRecordsOneEntryForAllMovedWindows() throws {
        for sourceNiri in [true, false] {
            let (fixture, tokens) = try mixedHistoryMakeFixture(sourceNiri: sourceNiri)
            let blocker = blockMixedHistoryRefreshes(fixture)
            defer { finishMixedHistoryRefreshes(fixture, blocker) }
            mixedHistoryCompleteLayout(fixture)
            mixedHistoryFocus(tokens[1], index: 0, fixture)
            XCTAssertTrue(fixture.controller.workspaceNavigationHandler.moveWindowsFromBar(
                [tokens[0], tokens[1]], toWorkspaceId: fixture.target
            ))
            mixedHistoryCompleteLayout(fixture)
            let targetGroups = sourceNiri
                ? [[tokens[2]], [tokens[0]], [tokens[1]]]
                : [[tokens[2]], [tokens[1]], [tokens[0]]]
            mixedHistoryAssertGroups(fixture, index: 0, groups: [])
            mixedHistoryAssertGroups(fixture, index: 1, groups: targetGroups)
            mixedHistoryAssertCounts(fixture, index: 0, undo: 1, redo: 0)
            mixedHistoryAssertCounts(fixture, index: 1, undo: 1, redo: 0)
            mixedHistoryFocus(tokens[2], index: 1, fixture)
            mixedHistoryCommand(.sizing(.undo), fixture)
            mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0], tokens[1]], ratio: 1)
            mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2]])
            mixedHistoryAssertCounts(fixture, index: 1, undo: 0, redo: 1)
            mixedHistoryFocus(tokens[2], index: 1, fixture)
            mixedHistoryCommand(.sizing(.redo), fixture)
            mixedHistoryAssertGroups(fixture, index: 0, groups: [])
            mixedHistoryAssertGroups(fixture, index: 1, groups: targetGroups)
            mixedHistoryAssertCounts(fixture, index: 1, undo: 1, redo: 0)
        }
    }

    func testDwindleWholeGroupDropIntoNiriUndoRedoRestoresTheGroup() throws {
        let (fixture, tokens) = try mixedHistoryMakeFixture(sourceNiri: false)
        let blocker = blockMixedHistoryRefreshes(fixture)
        defer { finishMixedHistoryRefreshes(fixture, blocker) }
        let peer = addWindow(4, to: fixture.source, fixture)
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            XCTAssertTrue(fixture.dwindle.groupWindow(tokens[1], into: peer, in: fixture.source))
        }
        fixture.controller.settings.gestures.dwindleGroupDragAcrossDisplays = .group
        mixedHistoryCompleteLayout(fixture)
        mixedHistoryFocus(tokens[1], index: 0, fixture)
        mixedHistoryDrop(fixture, token: tokens[1], placement: .niriNewColumn(durableIndex: 1))
        mixedHistoryAssertGroups(fixture, index: 0, groups: [[tokens[0]]])
        mixedHistoryAssertGroups(fixture, index: 1, groups: [[tokens[2]], [tokens[1], peer]])
        mixedHistoryAssertCounts(fixture, index: 0, undo: 1, redo: 0)
        mixedHistoryAssertCounts(fixture, index: 1, undo: 1, redo: 0)
        mixedHistoryFocus(tokens[0], index: 0, fixture)
        mixedHistoryCommand(.sizing(.undo), fixture)
        mixedHistoryAssertGroups(fixture, index: 0, groups: [[tokens[0]], [peer, tokens[1]]])
        mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2]])
        XCTAssertEqual(fixture.dwindle.root(for: fixture.source)?.splitRatio, 1)
        XCTAssertEqual(fixture.dwindle.tile(containing: peer, in: fixture.source)?.activeToken, tokens[1])
        mixedHistoryFocus(tokens[0], index: 0, fixture)
        mixedHistoryCommand(.sizing(.redo), fixture)
        mixedHistoryAssertGroups(fixture, index: 0, groups: [[tokens[0]]])
        mixedHistoryAssertGroups(fixture, index: 1, groups: [[tokens[2]], [tokens[1], peer]])
        mixedHistoryAssertCounts(fixture, index: 0, undo: 1, redo: 0)
    }

    func testMixedSwapUndoRedoRestoresBothLayoutsWithoutDuplicateHistory() throws {
        let (fixture, tokens) = try mixedHistoryMakeFixture(sourceNiri: true)
        let blocker = blockMixedHistoryRefreshes(fixture)
        defer { finishMixedHistoryRefreshes(fixture, blocker) }
        fixture.manager.withEngineMutationScope(in: fixture.target) {
            _ = fixture.dwindle.setPreselection(.right, in: fixture.target)
        }
        let peer = addWindow(4, to: fixture.target, fixture)
        mixedHistoryCompleteLayout(fixture)
        mixedHistoryFocus(tokens[1], index: 0, fixture)
        mixedHistoryDrop(fixture, token: tokens[1], placement: .swap(target: tokens[2]))
        mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0], tokens[2]])
        mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[1], peer], ratio: 1)
        mixedHistoryAssertCounts(fixture, index: 0, undo: 1, redo: 0)
        mixedHistoryAssertCounts(fixture, index: 1, undo: 1, redo: 0)
        mixedHistoryFocus(tokens[0], index: 0, fixture)
        mixedHistoryCommand(.sizing(.undo), fixture)
        mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0], tokens[1]])
        mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2], peer], ratio: 1)
        mixedHistoryFocus(tokens[0], index: 0, fixture)
        mixedHistoryCommand(.sizing(.redo), fixture)
        mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0], tokens[2]])
        mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[1], peer], ratio: 1)
        mixedHistoryAssertCounts(fixture, index: 0, undo: 1, redo: 0)
    }

    func testMixedDestinationUndoPreservesTheNiriPeersLaterWidth() throws {
        let (fixture, tokens) = try mixedHistoryMakeFixture(sourceNiri: true)
        let blocker = blockMixedHistoryRefreshes(fixture)
        defer { finishMixedHistoryRefreshes(fixture, blocker) }
        mixedHistoryCompleteLayout(fixture)
        mixedHistoryFocus(tokens[1], index: 0, fixture)
        mixedHistoryCommand(.workspace(.moveTo(1)), fixture)
        mixedHistoryFocus(tokens[0], index: 0, fixture)
        let laterProportion: CGFloat = 1 / 2
        mixedHistoryCommand(.sizing(.setContainerPrimarySpan(.setProportion(laterProportion * 100))), fixture)
        mixedHistoryFocus(tokens[2], index: 1, fixture)
        mixedHistoryCommand(.sizing(.undo), fixture)
        mixedHistoryAssertGroups(fixture, index: 0, groups: [[tokens[0]], [tokens[1]]])
        mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2]])
        XCTAssertEqual(fixture.niri.columns(in: fixture.source).first?.width, .proportion(laterProportion))
        XCTAssertEqual(fixture.niri.columns(in: fixture.source).last?.width, .proportion(1 / 4))
        let monitor = fixture.monitors[0]
        let area = fixture.controller.niriWorkingFrame(for: monitor)
        let gap = fixture.controller.innerGap(for: monitor)
        let width = NiriSizeChange.setProportion(laterProportion * 100).secondaryPixels(
            currentPixels: 0, availableSpan: area.width, gaps: gap
        )
        XCTAssertEqual(fixture.niri.findNode(for: tokens[0], in: fixture.source)?.frame?.width, width)
        mixedHistoryFocus(tokens[2], index: 1, fixture)
        mixedHistoryCommand(.sizing(.redo), fixture)
        mixedHistoryAssertGroups(fixture, index: 0, groups: [[tokens[0]]])
        mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2], tokens[1]], ratio: 1)
        XCTAssertEqual(fixture.niri.columns(in: fixture.source).first?.width, .proportion(laterProportion))
    }

    func testMixedTransferIntoEmptyTargetUndoRedoKeepsEmptyMembership() throws {
        for sourceNiri in [true, false] {
            let (fixture, tokens) = try mixedHistoryMakeFixture(sourceNiri: sourceNiri)
            let blocker = blockMixedHistoryRefreshes(fixture)
            defer { finishMixedHistoryRefreshes(fixture, blocker) }
            XCTAssertNotNil(fixture.manager.removeWindow(pid: tokens[2].pid, windowId: tokens[2].windowId))
            mixedHistoryCompleteLayout(fixture)
            mixedHistoryFocus(tokens[1], index: 0, fixture)
            mixedHistoryCommand(.workspace(.moveTo(1)), fixture)
            mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0]])
            mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[1]])
            mixedHistoryFocus(tokens[0], index: 0, fixture)
            mixedHistoryCommand(.sizing(.undo), fixture)
            mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0], tokens[1]], ratio: 1)
            mixedHistoryAssertGroups(fixture, index: 1, groups: [])
            XCTAssertNil(fixture.manager.entry(for: tokens[2]))
            mixedHistoryFocus(tokens[0], index: 0, fixture)
            mixedHistoryCommand(.sizing(.redo), fixture)
            mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0]])
            mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[1]])
        }
    }

    func testClosedMixedDepartureIsSkippedBeforeTheEarlierLocalUndo() throws {
        let (fixture, tokens) = try mixedHistoryMakeFixture(sourceNiri: true)
        let blocker = blockMixedHistoryRefreshes(fixture)
        defer { finishMixedHistoryRefreshes(fixture, blocker) }
        let survivor = addWindow(4, to: fixture.source, fixture)
        fixture.manager.setCachedConstraints(.unconstrained, for: survivor)
        mixedHistoryCompleteLayout(fixture)
        mixedHistoryFocus(tokens[0], index: 0, fixture)
        let changedProportion: CGFloat = 1 / 2
        mixedHistoryCommand(.sizing(.setContainerPrimarySpan(.setProportion(changedProportion * 100))), fixture)
        let changedColumn = try XCTUnwrap(fixture.niri.columns(in: fixture.source).first)
        XCTAssertTrue(changedColumn.hasManualSingleWindowWidthOverride)
        mixedHistoryFocus(tokens[1], index: 0, fixture)
        mixedHistoryCommand(.workspace(.moveTo(1)), fixture)
        XCTAssertTrue(changedColumn.hasManualSingleWindowWidthOverride)
        mixedHistoryAssertCounts(fixture, index: 0, undo: 2, redo: 0)
        XCTAssertNotNil(fixture.manager.removeWindow(pid: tokens[1].pid, windowId: tokens[1].windowId))
        mixedHistoryCompleteLayout(fixture)
        mixedHistoryFocus(tokens[0], index: 0, fixture)
        mixedHistoryCommand(.sizing(.undo), fixture)
        mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0], survivor])
        mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2]])
        mixedHistoryAssertCounts(fixture, index: 0, undo: 0, redo: 1)
        XCTAssertNil(fixture.manager.entry(for: tokens[1]))
        mixedHistoryCommand(.sizing(.redo), fixture)
        XCTAssertEqual(fixture.niri.columns(in: fixture.source).first?.width, .proportion(changedProportion))
        mixedHistoryAssertGroups(fixture, index: 0, groups: [[tokens[0]], [survivor]])
        XCTAssertNil(fixture.manager.entry(for: tokens[1]))
    }

    func testMixedSourceUndoFindsTheWindowInItsCurrentThirdWorkspace() throws {
        let (fixture, tokens) = try mixedHistoryMakeFixture(sourceNiri: true, thirdLayout: .niri)
        let blocker = blockMixedHistoryRefreshes(fixture)
        defer { finishMixedHistoryRefreshes(fixture, blocker) }
        let third = addWindow(4, to: fixture.workspaces[2], fixture)
        fixture.manager.setCachedConstraints(.unconstrained, for: third)
        mixedHistoryCompleteLayout(fixture)
        mixedHistoryFocus(tokens[1], index: 0, fixture)
        mixedHistoryCommand(.workspace(.moveTo(1)), fixture)
        mixedHistoryFocus(tokens[1], index: 1, fixture)
        mixedHistoryCommand(.workspace(.moveTo(2)), fixture)
        mixedHistoryAssertWorkspace(fixture, index: 2, tokens: [third, tokens[1]])
        mixedHistoryFocus(tokens[0], index: 0, fixture)
        mixedHistoryCommand(.sizing(.undo), fixture)
        mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0], tokens[1]])
        mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2]])
        mixedHistoryAssertWorkspace(fixture, index: 2, tokens: [third])
        mixedHistoryFocus(tokens[0], index: 0, fixture)
        mixedHistoryCommand(.sizing(.redo), fixture)
        mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0]])
        mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2]])
        mixedHistoryAssertWorkspace(fixture, index: 2, tokens: [third, tokens[1]])
    }

    func testMixedUndoRefusesActiveOrFloatingParticipantWithoutConsumingHistory() throws {
        for floating in [false, true] {
            let (fixture, tokens) = try mixedHistoryMakeFixture(sourceNiri: true)
            let blocker = blockMixedHistoryRefreshes(fixture)
            defer { finishMixedHistoryRefreshes(fixture, blocker) }
            mixedHistoryCompleteLayout(fixture)
            mixedHistoryFocus(tokens[1], index: 0, fixture)
            mixedHistoryCommand(.workspace(.moveTo(1)), fixture)
            mixedHistoryFocus(tokens[0], index: 0, fixture)
            if floating {
                XCTAssertTrue(fixture.manager.setWindowMode(.floating, for: tokens[1]))
            } else {
                let frame = try XCTUnwrap(fixture.frame(tokens[1]))
                XCTAssertTrue(fixture.dwindle.interactiveMoveBegin(
                    token: tokens[1], startLocation: frame.center, in: fixture.target
                ))
            }
            mixedHistoryCommand(.sizing(.undo), fixture)
            XCTAssertEqual(fixture.manager.workspace(for: tokens[1]), fixture.target)
            mixedHistoryAssertCounts(fixture, index: 0, undo: 1, redo: 0)
            mixedHistoryAssertCounts(fixture, index: 1, undo: 1, redo: 0)
            if floating {
                XCTAssertTrue(fixture.manager.setWindowMode(.tiling, for: tokens[1]))
                mixedHistoryCompleteLayout(fixture)
            } else {
                fixture.dwindle.interactiveMoveCancel()
            }
            mixedHistoryFocus(tokens[0], index: 0, fixture)
            mixedHistoryCommand(.sizing(.undo), fixture)
            mixedHistoryAssertWorkspace(fixture, index: 0, tokens: [tokens[0], tokens[1]])
            mixedHistoryAssertWorkspace(fixture, index: 1, tokens: [tokens[2]])
            mixedHistoryAssertCounts(fixture, index: 0, undo: 0, redo: 1)
        }
    }

    func testNiriArrivalRestorePreservesDeclaredPresentedFramesAndSampledMotion() throws {
        let engine = NiriLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let residentToken = WindowToken(pid: 1, windowId: 1)
        let arrivalToken = WindowToken(pid: 1, windowId: 2)
        let resident = engine.addWindow(token: residentToken, to: workspace, afterSelection: nil)
        _ = engine.addWindow(token: arrivalToken, to: workspace, afterSelection: resident.id)
        let snapshot = try XCTUnwrap(engine.layoutSnapshot(in: workspace, focused: residentToken))
        engine.removeWindow(token: arrivalToken, in: workspace)
        let arrival = NiriWindow(token: arrivalToken)
        let area = CGRect(x: 137, y: -241, width: 1512, height: 912)
        let displacement = CGPoint(x: -area.width / 8, y: area.height / 8)
        let spring = SpringAnimation(
            from: 1, to: 0, startTime: 0, config: engine.windowMovementAnimationConfig
        )
        let sample = spring.duration / 2
        let sampledValue = CGFloat(spring.value(at: sample))
        let expectedOffset = CGPoint(x: displacement.x * sampledValue, y: displacement.y * sampledValue)
        let windows = [resident, arrival]
        var presented: [WindowToken: CGRect] = [:]
        for (index, window) in windows.enumerated() {
            let target = CGRect(
                x: area.minX + CGFloat(index) * area.width / 2, y: area.minY,
                width: area.width / 2, height: area.height
            )
            let rendered = target.offsetBy(dx: expectedOffset.x, dy: expectedOffset.y)
            window.frame = target
            window.renderedFrame = rendered
            window.moveXAnimation = MoveAnimation(animation: spring, fromOffset: displacement.x)
            window.moveYAnimation = MoveAnimation(animation: spring, fromOffset: displacement.y)
            presented[window.token] = rendered
            XCTAssertEqual(window.renderOffset(at: sample), expectedOffset)
        }

        XCTAssertTrue(engine.restoreLayoutSnapshot(snapshot, in: workspace, arrivals: [arrival]))

        XCTAssertEqual(engine.columns(in: workspace).map { $0.windowNodes.map(\.token) }, [
            [residentToken], [arrivalToken]
        ])
        XCTAssertTrue(engine.findNode(for: residentToken, in: workspace) === resident)
        XCTAssertTrue(engine.findNode(for: arrivalToken, in: workspace) === arrival)
        XCTAssertEqual(engine.drawnLayout(in: workspace).frames, presented)
        for window in windows {
            XCTAssertTrue(window.moveXAnimation?.animation === spring)
            XCTAssertTrue(window.moveYAnimation?.animation === spring)
            XCTAssertEqual(window.renderOffset(at: sample), expectedOffset)
            XCTAssertFalse(window.tickMoveAnimations(at: spring.duration))
            XCTAssertEqual(window.renderOffset(at: spring.duration), .zero)
            XCTAssertFalse(window.hasMoveAnimationsRunning)
        }
    }

    private func mixedHistoryCommand(_ command: HotkeyCommand, _ fixture: Fixture) {
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(command), .executed)
        mixedHistoryCompleteLayout(fixture)
    }

    private func mixedHistoryDrop(_ fixture: Fixture, token: WindowToken, placement: CrossDisplayDrop.Placement) {
        let drop = CrossDisplayDrop(
            sourceToken: token, sourceWorkspaceId: fixture.source, workspaceId: fixture.target,
            monitor: fixture.monitors[1], placement: placement,
            previewFrame: fixture.controller.insetWorkingFrame(for: fixture.monitors[1])
        )
        XCTAssertNotNil(fixture.controller.crossDisplayDropPlan(for: drop))
        fixture.controller.performCrossDisplayDrop(drop)
        mixedHistoryCompleteLayout(fixture)
    }

    private func mixedHistoryAssertCounts(_ fixture: Fixture, index: Int, undo: Int, redo: Int) {
        let workspace = fixture.workspaces[index]
        if fixture.manager.activeLayoutKind(for: workspace) == .niri {
            XCTAssertEqual(fixture.niri.states[workspace]?.layoutHistory.undoSnapshots.count ?? 0, undo)
            XCTAssertEqual(fixture.niri.states[workspace]?.layoutHistory.redoSnapshots.count ?? 0, redo)
        } else {
            let counts = fixture.dwindle.layoutHistoryCounts(in: workspace)
            XCTAssertEqual(counts.undo, undo)
            XCTAssertEqual(counts.redo, redo)
        }
    }

    private func mixedHistoryAssertGroups(_ fixture: Fixture, index: Int, groups: [[WindowToken]]) {
        let workspace = fixture.workspaces[index]
        let actual: [[WindowToken]]
        if fixture.manager.activeLayoutKind(for: workspace) == .niri {
            actual = fixture.niri.columns(in: workspace).map { $0.windowNodes.map(\.token) }
        } else {
            actual = fixture.dwindle.root(for: workspace)?.collectAllLeaves()
                .compactMap { $0.tile?.members.map(\.token) } ?? []
        }
        XCTAssertEqual(actual, groups)
        XCTAssertEqual(Set(fixture.manager.entries(in: workspace).map(\.token)), Set(groups.flatMap { $0 }))
        for token in groups.flatMap({ $0 }) { XCTAssertEqual(fixture.manager.workspace(for: token), workspace) }
    }

    private func mixedHistoryFocus(_ token: WindowToken, index: Int, _ fixture: Fixture) {
        let workspace = fixture.workspaces[index]
        if fixture.manager.activeLayoutKind(for: workspace) == .niri {
            fixture.manager.withNiriViewportState(for: workspace) {
                $0.selectedNodeId = fixture.niri.findNode(for: token, in: workspace)?.id
            }
        } else {
            fixture.manager.withEngineMutationScope(in: workspace) {
                fixture.dwindle.setSelectedNode(fixture.dwindle.findNode(for: token, in: workspace), in: workspace)
            }
        }
        _ = fixture.controller.focusWindow(token, raisesWindow: false)
        mixedHistoryCompleteFocus(fixture)
    }

    private func mixedHistoryCompleteLayout(_ fixture: Fixture) {
        fixture.manager.withBatchedLayoutBuild {
            fixture.controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: Set(fixture.workspaces))
                + fixture.controller.dwindleLayoutHandler
                .layoutWithDwindleEngine(activeWorkspaces: Set(fixture.workspaces))
        }
        let refreshController = fixture.controller.layoutRefreshController
        if let refresh = refreshController.layoutState.pendingRefresh {
            let task = refreshController.layoutState.activeRefreshTask
            let blocked = refreshController.layoutState.activeRefresh
            refreshController.layoutState.pendingRefresh = nil
            refreshController.layoutState.activeRefresh = refresh
            refreshController.finishRefresh(
                refresh, didComplete: true, generation: refreshController.layoutState.refreshGeneration
            )
            refreshController.layoutState.activeRefreshTask = task
            refreshController.layoutState.activeRefresh = blocked
        }
        mixedHistoryCompleteFocus(fixture)
    }

    private func mixedHistoryCompleteFocus(_ fixture: Fixture) {
        guard let request = fixture.controller.intentLedger.activeManagedRequest else { return }
        XCTAssertTrue(fixture.manager.pendingManagedFocusMatches(
            token: request.token, workspaceId: request.workspaceId, requestId: request.requestId
        ))
        XCTAssertTrue(fixture.manager.confirmManagedFocus(
            request.token, in: request.workspaceId, activateWorkspaceOnMonitor: false, requestId: request.requestId
        ))
        XCTAssertNotNil(fixture.controller.intentLedger.confirmManagedRequest(
            token: request.token, source: .focusedWindowChanged
        ))
    }

    private func mixedHistoryAssertWorkspace(
        _ fixture: Fixture,
        index: Int,
        tokens: [WindowToken],
        ratio: CGFloat? = nil
    ) {
        let workspace = fixture.workspaces[index]
        if fixture.manager.activeLayoutKind(for: workspace) == .niri {
            mixedHistoryAssertNiri(fixture, index: index, tokens: tokens)
            return
        }
        let root = fixture.dwindle.root(for: workspace)
        let leaves = root?.collectAllLeaves() ?? []
        XCTAssertEqual(leaves.map { $0.tile?.members.map(\.token) ?? [] }, tokens.map { [$0] })
        XCTAssertEqual(Set(fixture.manager.entries(in: workspace).map(\.token)), Set(tokens))
        XCTAssertEqual(root?.splitRatio, ratio)
        XCTAssertEqual(root?.splitOrientation, tokens.count == 1 ? nil : .horizontal)
        XCTAssertEqual(fixture.dwindle.existingState(for: workspace)?.tileCount, tokens.count)
        for token in tokens {
            XCTAssertEqual(fixture.manager.workspace(for: token), workspace)
            XCTAssertNotNil(fixture.dwindle.findNode(for: token, in: workspace))
        }
        let monitor = fixture.controller.layoutRefreshController.buildMonitorSnapshot(for: fixture.monitors[index])
        let area = monitor.workingFrame
        let cut = area.width * (ratio ?? 1) / 2
        var expected: [WindowToken: CGRect] = [:]
        for (position, token) in tokens.enumerated() {
            if tokens.count == 1 {
                expected[token] = fixture.dwindle.settings.singleWindowFit.frame(in: monitor.borderSafeFillFrame)
            } else {
                let raw = CGRect(
                    x: position == 0 ? area.minX : area.minX + cut,
                    y: area.minY,
                    width: position == 0 ? cut : area.width - cut,
                    height: area.height
                )
                expected[token] = DwindleGapCalculator.applyGaps(
                    nodeRect: raw, tilingArea: area, settings: fixture.dwindle.settings
                )
            }
        }
        XCTAssertEqual(fixture.dwindle.currentFrames(in: workspace), expected)
        XCTAssertEqual(fixture.dwindle.fullscreenTokens(in: workspace), [])
    }

    private func mixedHistoryMakeFixture(
        sourceNiri: Bool,
        thirdLayout: LayoutType? = nil
    ) throws -> (Fixture, [WindowToken]) {
        let layouts: [LayoutType] = (sourceNiri ? [.niri, .dwindle] : [.dwindle, .niri]) +
            (thirdLayout.map { [$0] } ?? [])
        let fixture = try makeNativeFixture(
            layouts, orientations: Array(repeating: .horizontal, count: layouts.count),
            frames: [
                CGRect(x: 137, y: -241, width: 1512, height: 912),
                CGRect(x: 1649, y: 173, width: 1712, height: 1012),
                CGRect(x: 3361, y: 173, width: 1512, height: 912)
            ]
        )
        fixture.controller.settings.focus.followsWindowToMonitor = false
        fixture.controller.settings.niri.defaultContainerPrimarySpan = 1 / 4
        fixture.controller.settings.niri.centerFocusedColumn = .never
        fixture.controller.settings.niri.alwaysCenterSingleColumn = false
        fixture.controller.settings.niri.keepExistingWindowWidth = false
        fixture.controller.settings.niri.opensNewWindowsAtAppWidth = false
        fixture.controller.niriLayoutHandler.syncMonitorsToNiriEngine()
        let first = addWindow(1, to: fixture.source, fixture)
        if !sourceNiri {
            fixture.manager.withEngineMutationScope(in: fixture.source) {
                _ = fixture.dwindle.setPreselection(.right, in: fixture.source)
            }
        }
        let moved = addWindow(2, to: fixture.source, fixture)
        let resident = addWindow(3, to: fixture.target, fixture)
        for token in [first, moved, resident] {
            fixture.manager.setCachedConstraints(.unconstrained, for: token)
        }
        return (fixture, [first, moved, resident])
    }

    private func mixedHistoryAssertNiri(_ fixture: Fixture, index: Int, tokens: [WindowToken]) {
        let workspace = fixture.workspaces[index]
        let columns = fixture.niri.columns(in: workspace)
        let expectedGroups = tokens.map { [$0] }
        XCTAssertEqual(columns.map { $0.windowNodes.map(\.token) }, expectedGroups)
        XCTAssertEqual(Set(fixture.manager.entries(in: workspace).map(\.token)), Set(tokens))
        let monitor = fixture.controller.layoutRefreshController.buildMonitorSnapshot(for: fixture.monitors[index])
        let area = fixture.controller.niriWorkingFrame(for: fixture.monitors[index])
        let gap = fixture.controller.innerGap(for: fixture.monitors[index], scale: monitor.scale)
        let proportion: CGFloat = 1 / 4
        let width = NiriSizeChange.setProportion(proportion * 100).secondaryPixels(
            currentPixels: 0, availableSpan: area.width, gaps: gap
        )
        for (position, token) in tokens.enumerated() {
            XCTAssertEqual(fixture.manager.workspace(for: token), workspace)
            XCTAssertNil(fixture.dwindle.findNode(for: token, in: workspace))
            let window = fixture.niri.findNode(for: token, in: workspace)
            XCTAssertNotNil(window)
            XCTAssertEqual(columns[position].width, .proportion(proportion))
            if tokens.count == 1 {
                XCTAssertEqual(window?.frame, monitor.borderSafeFillFrame)
            } else {
                let height = area.height - gap * CGFloat(expectedGroups[position].count + 1)
                XCTAssertEqual(window?.frame?.size, CGSize(width: width, height: height))
                if position > 0, let previous = columns[position - 1].windowNodes.first?.frame,
                   let frame = window?.frame
                {
                    XCTAssertEqual(frame.minX - previous.minX, width + gap)
                    XCTAssertEqual(frame.minY, previous.minY)
                }
            }
        }
    }

    private struct MixedHistoryRefreshBlocker {
        let task: Task<Void, Never>
        let completion: AsyncStream<Void>.Continuation
    }

    private func blockMixedHistoryRefreshes(_ fixture: Fixture) -> MixedHistoryRefreshBlocker {
        let (events, completion) = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            var iterator = events.makeAsyncIterator()
            _ = await iterator.next()
        }
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = task
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout, reason: .layoutCommand, affectedWorkspaceIds: Set(fixture.workspaces)
        )
        fixture.controller.motionPolicy.animationsEnabled = false
        fixture.controller.hasStartedServices = true
        return MixedHistoryRefreshBlocker(task: task, completion: completion)
    }

    private func finishMixedHistoryRefreshes(_ fixture: Fixture, _ blocker: MixedHistoryRefreshBlocker) {
        blocker.completion.finish()
        blocker.task.cancel()
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = nil
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = nil
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
    }
}
