// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

extension CrossDisplayDragTests {
    func testDwindleWorkspaceMoveCommandUndoRedoRestoresSourceAndDestination() throws {
        let (fixture, tokens) = try makeDwindleTransferHistoryFixture()
        let blocker = blockDwindleTransferHistoryRefreshes(fixture)
        defer { finishDwindleTransferHistoryRefreshes(fixture, blocker) }
        let originalRatio: CGFloat = 3 / 4
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            fixture.dwindle.root(for: fixture.source)?.kind = .split(orientation: .horizontal, ratio: originalRatio)
        }
        completeDwindleTransferHistoryLayout(fixture)
        assertDwindleTransferHistoryWorkspace(
            fixture,
            index: 0,
            groups: [[tokens[0]], [tokens[1]]],
            ratio: originalRatio
        )
        assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[2]]])
        focusDwindleTransferHistoryToken(tokens[1], index: 0, fixture)

        stepDwindleTransferHistoryCommand(.workspace(.moveTo(1)), fixture)

        assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]]])
        assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[2]], [tokens[1]]], ratio: 1)
        focusDwindleTransferHistoryToken(tokens[0], index: 0, fixture)
        stepDwindleTransferHistoryCommand(.sizing(.undo), fixture)
        assertDwindleTransferHistoryWorkspace(
            fixture,
            index: 0,
            groups: [[tokens[0]], [tokens[1]]],
            ratio: originalRatio
        )
        assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[2]]])
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.source)
        XCTAssertEqual(fixture.dwindle.projectedActiveToken(in: fixture.source), tokens[1])
        focusDwindleTransferHistoryToken(tokens[0], index: 0, fixture)
        stepDwindleTransferHistoryCommand(.sizing(.redo), fixture)
        assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]]])
        assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[2]], [tokens[1]]], ratio: 1)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.target)
        XCTAssertEqual(fixture.dwindle.projectedActiveToken(in: fixture.source), tokens[0])
    }

    func testDwindleDestinationUndoReturnsGroupMemberAndPreservesLaterSourceRatio() throws {
        let (fixture, tokens) = try makeDwindleTransferHistoryFixture()
        let blocker = blockDwindleTransferHistoryRefreshes(fixture)
        defer { finishDwindleTransferHistoryRefreshes(fixture, blocker) }
        let peer = addWindow(4, to: fixture.source, fixture)
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            XCTAssertTrue(fixture.dwindle.groupWindow(tokens[1], into: peer, in: fixture.source))
        }
        completeDwindleTransferHistoryLayout(fixture)
        assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]], [peer, tokens[1]]], ratio: 1)
        focusDwindleTransferHistoryToken(tokens[1], index: 0, fixture)
        stepDwindleTransferHistoryCommand(.workspace(.moveTo(1)), fixture)
        assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]], [peer]], ratio: 1)
        focusDwindleTransferHistoryToken(tokens[0], index: 0, fixture)
        stepDwindleTransferHistoryCommand(.dwindle(.resizeAlongAxis(.horizontal, true)), fixture)
        let laterRatio = 1 + fixture.dwindle.settings.resizeStep
        assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]], [peer]], ratio: laterRatio)
        focusDwindleTransferHistoryToken(tokens[2], index: 1, fixture)

        stepDwindleTransferHistoryCommand(.sizing(.undo), fixture)

        assertDwindleTransferHistoryWorkspace(
            fixture,
            index: 0,
            groups: [[tokens[0]], [peer, tokens[1]]],
            ratio: laterRatio
        )
        assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[2]]])
        XCTAssertEqual(fixture.dwindle.tile(containing: peer, in: fixture.source)?.activeToken, tokens[1])
        XCTAssertEqual(fixture.dwindle.projectedActiveToken(in: fixture.source), tokens[1])
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.source)
        focusDwindleTransferHistoryToken(tokens[2], index: 1, fixture)
        stepDwindleTransferHistoryCommand(.sizing(.redo), fixture)
        assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]], [peer]], ratio: laterRatio)
        assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[2]], [tokens[1]]], ratio: 1)
        XCTAssertEqual(fixture.dwindle.projectedActiveToken(in: fixture.source), peer)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.target)
    }

    func testDwindleWholeGroupDropHistoryWorksFromEitherWorkspace() throws {
        for historyIndex in [0, 1] {
            let (fixture, tokens) = try makeDwindleTransferHistoryFixture()
            let blocker = blockDwindleTransferHistoryRefreshes(fixture)
            defer { finishDwindleTransferHistoryRefreshes(fixture, blocker) }
            let peer = addWindow(4, to: fixture.source, fixture)
            fixture.manager.withEngineMutationScope(in: fixture.source) {
                XCTAssertTrue(fixture.dwindle.groupWindow(tokens[1], into: peer, in: fixture.source))
            }
            fixture.controller.settings.gestures.dwindleGroupDragAcrossDisplays = .group
            completeDwindleTransferHistoryLayout(fixture)
            focusDwindleTransferHistoryToken(tokens[1], index: 0, fixture)
            performDwindleTransferHistoryDrop(
                fixture, token: tokens[1], placement: .dwindleBeside(target: tokens[2], direction: .right)
            )
            assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]]])
            assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[2]], [peer, tokens[1]]], ratio: 1)
            assertDwindleTransferHistoryCounts(fixture, index: 0, undo: 1, redo: 0)
            assertDwindleTransferHistoryCounts(fixture, index: 1, undo: 1, redo: 0)
            let resident = historyIndex == 0 ? tokens[0] : tokens[2]
            focusDwindleTransferHistoryToken(resident, index: historyIndex, fixture)
            stepDwindleTransferHistoryCommand(.sizing(.undo), fixture)
            assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]], [peer, tokens[1]]], ratio: 1)
            assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[2]]])
            assertDwindleTransferHistoryCounts(fixture, index: historyIndex, undo: 0, redo: 1)
            focusDwindleTransferHistoryToken(resident, index: historyIndex, fixture)
            stepDwindleTransferHistoryCommand(.sizing(.redo), fixture)
            assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]]])
            assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[2]], [peer, tokens[1]]], ratio: 1)
            assertDwindleTransferHistoryCounts(fixture, index: historyIndex, undo: 1, redo: 0)
        }
    }

    func testDwindleSwapDropHistoryWorksFromEitherWorkspace() throws {
        for historyIndex in [0, 1] {
            let (fixture, tokens) = try makeDwindleTransferHistoryFixture()
            let blocker = blockDwindleTransferHistoryRefreshes(fixture)
            defer { finishDwindleTransferHistoryRefreshes(fixture, blocker) }
            fixture.manager.withEngineMutationScope(in: fixture.target) {
                _ = fixture.dwindle.setPreselection(.right, in: fixture.target)
            }
            let targetPeer = addWindow(4, to: fixture.target, fixture)
            completeDwindleTransferHistoryLayout(fixture)
            focusDwindleTransferHistoryToken(tokens[1], index: 0, fixture)
            performDwindleTransferHistoryDrop(fixture, token: tokens[1], placement: .swap(target: tokens[2]))
            assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]], [tokens[2]]], ratio: 1)
            assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[1]], [targetPeer]], ratio: 1)
            let resident = historyIndex == 0 ? tokens[0] : targetPeer
            focusDwindleTransferHistoryToken(resident, index: historyIndex, fixture)
            stepDwindleTransferHistoryCommand(.sizing(.undo), fixture)
            assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]], [tokens[1]]], ratio: 1)
            assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[2]], [targetPeer]], ratio: 1)
            assertDwindleTransferHistoryCounts(fixture, index: historyIndex, undo: 0, redo: 1)
            focusDwindleTransferHistoryToken(resident, index: historyIndex, fixture)
            stepDwindleTransferHistoryCommand(.sizing(.redo), fixture)
            assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]], [tokens[2]]], ratio: 1)
            assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[1]], [targetPeer]], ratio: 1)
            assertDwindleTransferHistoryCounts(fixture, index: historyIndex, undo: 1, redo: 0)
        }
    }

    func testDwindleBarMultiTokenTransferRecordsOneHistoryEntry() throws {
        let (fixture, tokens) = try makeDwindleTransferHistoryFixture()
        let blocker = blockDwindleTransferHistoryRefreshes(fixture)
        defer { finishDwindleTransferHistoryRefreshes(fixture, blocker) }
        completeDwindleTransferHistoryLayout(fixture)
        focusDwindleTransferHistoryToken(tokens[1], index: 0, fixture)
        XCTAssertTrue(fixture.controller.workspaceNavigationHandler.moveWindowsFromBar(
            [tokens[0], tokens[1]], toWorkspaceId: fixture.target
        ))
        completeDwindleTransferHistoryLayout(fixture)
        assertDwindleTransferHistoryMembership(fixture, index: 0, groups: [])
        assertDwindleTransferHistoryMembership(fixture, index: 1, groups: [[tokens[2]], [tokens[0]], [tokens[1]]])
        XCTAssertEqual(fixture.dwindle.root(for: fixture.target)?.splitOrientation, .horizontal)
        XCTAssertEqual(fixture.dwindle.root(for: fixture.target)?.secondChild()?.splitOrientation, .horizontal)
        assertDwindleTransferHistoryCounts(fixture, index: 0, undo: 1, redo: 0)
        assertDwindleTransferHistoryCounts(fixture, index: 1, undo: 1, redo: 0)
        focusDwindleTransferHistoryToken(tokens[2], index: 1, fixture)
        stepDwindleTransferHistoryCommand(.sizing(.undo), fixture)
        assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]], [tokens[1]]], ratio: 1)
        assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[2]]])
        assertDwindleTransferHistoryCounts(fixture, index: 1, undo: 0, redo: 1)
        focusDwindleTransferHistoryToken(tokens[2], index: 1, fixture)
        stepDwindleTransferHistoryCommand(.sizing(.redo), fixture)
        assertDwindleTransferHistoryMembership(fixture, index: 0, groups: [])
        assertDwindleTransferHistoryMembership(fixture, index: 1, groups: [[tokens[2]], [tokens[0]], [tokens[1]]])
        assertDwindleTransferHistoryCounts(fixture, index: 1, undo: 1, redo: 0)
        try assertDwindleEmptyPortraitBarTransfer()
    }

    func testDwindleTransferHistorySkipsClosedTokenWithoutResurrection() throws {
        let (fixture, tokens) = try makeDwindleTransferHistoryFixture()
        let blocker = blockDwindleTransferHistoryRefreshes(fixture)
        defer { finishDwindleTransferHistoryRefreshes(fixture, blocker) }
        completeDwindleTransferHistoryLayout(fixture)
        focusDwindleTransferHistoryToken(tokens[1], index: 0, fixture)
        stepDwindleTransferHistoryCommand(.workspace(.moveTo(1)), fixture)
        XCTAssertNotNil(fixture.manager.removeWindow(pid: tokens[1].pid, windowId: tokens[1].windowId))
        completeDwindleTransferHistoryLayout(fixture)
        focusDwindleTransferHistoryToken(tokens[0], index: 0, fixture)
        for command: HotkeyCommand in [.sizing(.undo), .sizing(.redo)] {
            stepDwindleTransferHistoryCommand(command, fixture)
            assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]]])
            assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[2]]])
            XCTAssertNil(fixture.manager.entry(for: tokens[1]))
            XCTAssertNil(fixture.dwindle.findNode(for: tokens[1], in: fixture.source))
            XCTAssertNil(fixture.dwindle.findNode(for: tokens[1], in: fixture.target))
            assertDwindleTransferHistoryCounts(fixture, index: 0, undo: 0, redo: 0)
        }
    }

    func testDwindleUndoSkipsStaleTransferAndLocalEntriesBeforeAnOlderTransfer() throws {
        let (fixture, tokens) = try makeDwindleTransferHistoryFixture()
        let blocker = blockDwindleTransferHistoryRefreshes(fixture)
        defer { finishDwindleTransferHistoryRefreshes(fixture, blocker) }
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            _ = fixture.dwindle.setPreselection(.right, in: fixture.source)
        }
        let closing = addWindow(4, to: fixture.source, fixture)
        completeDwindleTransferHistoryLayout(fixture)
        assertDwindleTransferHistoryMembership(fixture, index: 0, groups: [[tokens[0]], [tokens[1]], [closing]])
        XCTAssertEqual(fixture.dwindle.root(for: fixture.source)?.secondChild()?.splitOrientation, .horizontal)
        focusDwindleTransferHistoryToken(tokens[0], index: 0, fixture)
        stepDwindleTransferHistoryCommand(.workspace(.moveTo(1)), fixture)
        assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[1]], [closing]], ratio: 1)
        focusDwindleTransferHistoryToken(tokens[1], index: 0, fixture)
        stepDwindleTransferHistoryCommand(.dwindle(.resizeAlongAxis(.horizontal, true)), fixture)
        assertDwindleTransferHistoryWorkspace(
            fixture, index: 0, groups: [[tokens[1]], [closing]], ratio: 1 + fixture.dwindle.settings.resizeStep
        )
        focusDwindleTransferHistoryToken(closing, index: 0, fixture)
        stepDwindleTransferHistoryCommand(.workspace(.moveTo(1)), fixture)
        XCTAssertNotNil(fixture.manager.removeWindow(pid: closing.pid, windowId: closing.windowId))
        completeDwindleTransferHistoryLayout(fixture)
        focusDwindleTransferHistoryToken(tokens[1], index: 0, fixture)
        assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[1]]])
        assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[2]], [tokens[0]]], ratio: 1)
        assertDwindleTransferHistoryCounts(fixture, index: 0, undo: 3, redo: 0)

        stepDwindleTransferHistoryCommand(.sizing(.undo), fixture)

        assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]], [tokens[1]]], ratio: 1)
        assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[2]]])
        assertDwindleTransferHistoryCounts(fixture, index: 0, undo: 0, redo: 1)
        XCTAssertNil(fixture.manager.entry(for: closing))
        XCTAssertNil(fixture.dwindle.findNode(for: closing, in: fixture.source))
        XCTAssertNil(fixture.dwindle.findNode(for: closing, in: fixture.target))
    }

    func testDwindleSourceHistoryReturnsWindowFromItsCurrentThirdWorkspace() throws {
        let fixture = try makeNativeFixture(
            [.dwindle, .dwindle, .dwindle],
            orientations: [.horizontal, .horizontal, .horizontal]
        )
        fixture.controller.settings.focus.followsWindowToMonitor = false
        fixture.controller.motionPolicy.animationsEnabled = false
        let blocker = blockDwindleTransferHistoryRefreshes(fixture)
        defer { finishDwindleTransferHistoryRefreshes(fixture, blocker) }
        let first = addWindow(1, to: fixture.source, fixture)
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            _ = fixture.dwindle.setPreselection(.right, in: fixture.source)
        }
        let moved = addWindow(2, to: fixture.source, fixture)
        let target = addWindow(3, to: fixture.target, fixture)
        let third = addWindow(4, to: fixture.workspaces[2], fixture)
        completeDwindleTransferHistoryLayout(fixture)
        focusDwindleTransferHistoryToken(moved, index: 0, fixture)
        stepDwindleTransferHistoryCommand(.workspace(.moveTo(1)), fixture)
        focusDwindleTransferHistoryToken(moved, index: 1, fixture)
        stepDwindleTransferHistoryCommand(.workspace(.moveTo(2)), fixture)
        assertDwindleTransferHistoryWorkspace(fixture, index: 2, groups: [[third], [moved]], ratio: 1)
        focusDwindleTransferHistoryToken(first, index: 0, fixture)
        stepDwindleTransferHistoryCommand(.sizing(.undo), fixture)
        assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[first], [moved]], ratio: 1)
        assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[target]])
        assertDwindleTransferHistoryWorkspace(fixture, index: 2, groups: [[third]])
        focusDwindleTransferHistoryToken(first, index: 0, fixture)
        stepDwindleTransferHistoryCommand(.sizing(.redo), fixture)
        assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[first]])
        assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[target]])
        assertDwindleTransferHistoryWorkspace(fixture, index: 2, groups: [[third], [moved]], ratio: 1)
    }

    func testDwindleTransferHistoryRefusesActiveGestureAndMixedParticipantWithoutConsuming() throws {
        for mixedLayout in [false, true] {
            let (fixture, tokens) = try makeDwindleTransferHistoryFixture()
            let blocker = blockDwindleTransferHistoryRefreshes(fixture)
            defer { finishDwindleTransferHistoryRefreshes(fixture, blocker) }
            completeDwindleTransferHistoryLayout(fixture)
            focusDwindleTransferHistoryToken(tokens[1], index: 0, fixture)
            stepDwindleTransferHistoryCommand(.workspace(.moveTo(1)), fixture)
            focusDwindleTransferHistoryToken(tokens[0], index: 0, fixture)
            if mixedLayout {
                XCTAssertTrue(fixture.controller.commandHandler.setWorkspaceLayout(.niri, forWorkspaceNamed: "2"))
            } else {
                let frame = try XCTUnwrap(fixture.frame(tokens[0]))
                XCTAssertTrue(fixture.dwindle.interactiveMoveBegin(
                    token: tokens[0], startLocation: frame.center, in: fixture.source
                ))
            }
            stepDwindleTransferHistoryCommand(.sizing(.undo), fixture)
            XCTAssertEqual(fixture.manager.workspace(for: tokens[1]), fixture.target)
            assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]]])
            assertDwindleTransferHistoryCounts(fixture, index: 0, undo: 1, redo: 0)
            assertDwindleTransferHistoryCounts(fixture, index: 1, undo: 1, redo: 0)
            if mixedLayout {
                XCTAssertTrue(fixture.controller.commandHandler.setWorkspaceLayout(.dwindle, forWorkspaceNamed: "2"))
                completeDwindleTransferHistoryLayout(fixture)
            } else {
                fixture.dwindle.interactiveMoveCancel()
            }
            focusDwindleTransferHistoryToken(tokens[0], index: 0, fixture)
            stepDwindleTransferHistoryCommand(.sizing(.undo), fixture)
            assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]], [tokens[1]]], ratio: 1)
            assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[2]]])
            assertDwindleTransferHistoryCounts(fixture, index: 0, undo: 0, redo: 1)
        }
    }

    func testDwindleCommandTransferPreservesSmartSplitKeyboardPlacement() throws {
        for smartSplit in [false, true] {
            let (fixture, tokens) = try makeDwindleTransferHistoryFixture()
            let blocker = blockDwindleTransferHistoryRefreshes(fixture)
            defer { finishDwindleTransferHistoryRefreshes(fixture, blocker) }
            fixture.controller.settings.dwindle.smartSplit = smartSplit
            completeDwindleTransferHistoryLayout(fixture)
            focusDwindleTransferHistoryToken(tokens[1], index: 0, fixture)
            stepDwindleTransferHistoryCommand(.workspace(.moveTo(1)), fixture)
            assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]]])
            assertDwindleTransferHistoryWorkspace(
                fixture, index: 1, groups: smartSplit ? [[tokens[1]], [tokens[2]]] : [[tokens[2]], [tokens[1]]],
                ratio: 1, orientation: smartSplit ? .vertical : .horizontal
            )
            focusDwindleTransferHistoryToken(tokens[0], index: 0, fixture)
            stepDwindleTransferHistoryCommand(.sizing(.undo), fixture)
            assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[tokens[0]], [tokens[1]]], ratio: 1)
            assertDwindleTransferHistoryWorkspace(fixture, index: 1, groups: [[tokens[2]]])
        }
    }

    func testDwindleFloatingBarTransferKeepsFloatingRouteOutsideTiledHistory() throws {
        let (fixture, tokens) = try makeDwindleTransferHistoryFixture()
        let blocker = blockDwindleTransferHistoryRefreshes(fixture)
        defer { finishDwindleTransferHistoryRefreshes(fixture, blocker) }
        let area = fixture.controller.insetWorkingFrame(for: fixture.monitors[0])
        let floatingFrame = CGRect(origin: area.origin, size: CGSize(width: area.width / 3, height: area.height / 3))
        XCTAssertTrue(fixture.manager.setWindowMode(.floating, for: tokens[1]))
        fixture.manager.updateFloatingGeometry(
            frame: floatingFrame,
            for: tokens[1],
            referenceMonitor: fixture.monitors[0]
        )
        completeDwindleTransferHistoryLayout(fixture)
        focusDwindleTransferHistoryToken(tokens[1], index: 0, fixture)
        XCTAssertEqual(fixture.manager.windowMode(for: tokens[1]), .floating)
        XCTAssertTrue(fixture.controller.workspaceNavigationHandler.moveWindowsFromBar(
            [tokens[1]],
            toWorkspaceId: fixture.target
        ))
        completeDwindleTransferHistoryLayout(fixture)
        XCTAssertEqual(fixture.manager.workspace(for: tokens[1]), fixture.target)
        XCTAssertEqual(fixture.manager.windowMode(for: tokens[1]), .floating)
        XCTAssertEqual(fixture.manager.floatingState(for: tokens[1])?.referenceMonitorId, fixture.monitors[1].id)
        XCTAssertEqual(fixture.manager.floatingState(for: tokens[1])?.lastFrame.size, floatingFrame.size)
        XCTAssertNil(fixture.dwindle.findNode(for: tokens[1], in: fixture.source))
        XCTAssertNil(fixture.dwindle.findNode(for: tokens[1], in: fixture.target))
        XCTAssertEqual(Set(fixture.manager.entries(in: fixture.target).map(\.token)), Set([tokens[1], tokens[2]]))
        assertDwindleTransferHistoryCounts(fixture, index: 0, undo: 0, redo: 0)
        assertDwindleTransferHistoryCounts(fixture, index: 1, undo: 0, redo: 0)
    }

    private func performDwindleTransferHistoryDrop(
        _ fixture: Fixture, token: WindowToken, placement: CrossDisplayDrop.Placement
    ) {
        let drop = CrossDisplayDrop(
            sourceToken: token, sourceWorkspaceId: fixture.source, workspaceId: fixture.target,
            monitor: fixture.monitors[1], placement: placement,
            previewFrame: fixture.controller.insetWorkingFrame(for: fixture.monitors[1])
        )
        XCTAssertNotNil(fixture.controller.crossDisplayDropPlan(for: drop))
        fixture.controller.performCrossDisplayDrop(drop)
        completeDwindleTransferHistoryLayout(fixture)
    }

    private func assertDwindleEmptyPortraitBarTransfer() throws {
        let fixture = try makeNativeFixture(
            [.dwindle, .dwindle], orientations: [.horizontal, .vertical],
            frames: [
                CGRect(x: 137, y: -241, width: 1512, height: 912),
                CGRect(x: 1649, y: 173, width: 912, height: 1512)
            ]
        )
        fixture.controller.settings.focus.followsWindowToMonitor = false
        fixture.controller.motionPolicy.animationsEnabled = false
        let blocker = blockDwindleTransferHistoryRefreshes(fixture)
        defer { finishDwindleTransferHistoryRefreshes(fixture, blocker) }
        let first = addWindow(1, to: fixture.source, fixture)
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            _ = fixture.dwindle.setPreselection(.right, in: fixture.source)
        }
        let second = addWindow(2, to: fixture.source, fixture)
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            _ = fixture.dwindle.setPreselection(.right, in: fixture.source)
        }
        let resident = addWindow(3, to: fixture.source, fixture)
        completeDwindleTransferHistoryLayout(fixture)
        focusDwindleTransferHistoryToken(resident, index: 0, fixture)
        XCTAssertTrue(fixture.controller.workspaceNavigationHandler.moveWindowsFromBar(
            [first, second], toWorkspaceId: fixture.target
        ))
        completeDwindleTransferHistoryLayout(fixture)
        assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[resident]])
        assertDwindleTransferHistoryWorkspace(
            fixture,
            index: 1,
            groups: [[second], [first]],
            ratio: 1,
            orientation: .vertical
        )
        assertDwindleTransferHistoryCounts(fixture, index: 0, undo: 1, redo: 0)
        assertDwindleTransferHistoryCounts(fixture, index: 1, undo: 1, redo: 0)
        stepDwindleTransferHistoryCommand(.sizing(.undo), fixture)
        assertDwindleTransferHistoryMembership(fixture, index: 0, groups: [[first], [second], [resident]])
        XCTAssertEqual(fixture.dwindle.root(for: fixture.source)?.splitOrientation, .horizontal)
        XCTAssertEqual(fixture.dwindle.root(for: fixture.source)?.secondChild()?.splitOrientation, .horizontal)
        assertDwindleTransferHistoryMembership(fixture, index: 1, groups: [])
        focusDwindleTransferHistoryToken(resident, index: 0, fixture)
        stepDwindleTransferHistoryCommand(.sizing(.redo), fixture)
        assertDwindleTransferHistoryWorkspace(fixture, index: 0, groups: [[resident]])
        assertDwindleTransferHistoryWorkspace(
            fixture,
            index: 1,
            groups: [[second], [first]],
            ratio: 1,
            orientation: .vertical
        )
        assertDwindleTransferHistoryCounts(fixture, index: 0, undo: 1, redo: 0)
    }

    private func assertDwindleTransferHistoryCounts(_ fixture: Fixture, index: Int, undo: Int, redo: Int) {
        let counts = fixture.dwindle.layoutHistoryCounts(in: fixture.workspaces[index])
        XCTAssertEqual(counts.undo, undo)
        XCTAssertEqual(counts.redo, redo)
    }

    private func makeDwindleTransferHistoryFixture() throws -> (Fixture, [WindowToken]) {
        let fixture = try makeNativeFixture(
            [.dwindle, .dwindle], orientations: [.horizontal, .horizontal],
            frames: [
                CGRect(x: 137, y: -241, width: 1512, height: 912),
                CGRect(x: 1649, y: 173, width: 1712, height: 1012)
            ]
        )
        fixture.controller.settings.focus.followsWindowToMonitor = false
        fixture.controller.motionPolicy.animationsEnabled = false
        let first = addWindow(1, to: fixture.source, fixture)
        fixture.manager.withEngineMutationScope(in: fixture.source) {
            _ = fixture.dwindle.setPreselection(.right, in: fixture.source)
        }
        let moved = addWindow(2, to: fixture.source, fixture)
        let resident = addWindow(3, to: fixture.target, fixture)
        return (fixture, [first, moved, resident])
    }

    private func focusDwindleTransferHistoryToken(_ token: WindowToken, index: Int, _ fixture: Fixture) {
        let workspace = fixture.workspaces[index]
        fixture.manager.withEngineMutationScope(in: workspace) {
            fixture.dwindle.setSelectedNode(fixture.dwindle.findNode(for: token, in: workspace), in: workspace)
        }
        _ = fixture.controller.focusWindow(token, raisesWindow: false)
        completeDwindleTransferHistoryFocus(fixture)
        XCTAssertEqual(fixture.manager.selectedManagedToken, token)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, workspace)
    }

    private func stepDwindleTransferHistoryCommand(_ command: HotkeyCommand, _ fixture: Fixture) {
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(command), .executed)
        completeDwindleTransferHistoryLayout(fixture)
    }

    private func completeDwindleTransferHistoryLayout(_ fixture: Fixture) {
        fixture.manager.withBatchedLayoutBuild {
            fixture.controller.dwindleLayoutHandler.layoutWithDwindleEngine(activeWorkspaces: Set(fixture.workspaces))
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
        completeDwindleTransferHistoryFocus(fixture)
    }

    private func completeDwindleTransferHistoryFocus(_ fixture: Fixture) {
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

    private func assertDwindleTransferHistoryWorkspace(
        _ fixture: Fixture, index: Int, groups: [[WindowToken]], ratio: CGFloat? = nil,
        orientation: DwindleOrientation = .horizontal
    ) {
        let workspace = fixture.workspaces[index]
        let root = fixture.dwindle.root(for: workspace)
        let leaves = root?.collectAllLeaves() ?? []
        assertDwindleTransferHistoryMembership(fixture, index: index, groups: groups)
        XCTAssertEqual(root?.splitRatio, ratio)
        XCTAssertEqual(root?.splitOrientation, groups.count == 1 ? nil : orientation)
        let monitor = fixture.controller.layoutRefreshController.buildMonitorSnapshot(for: fixture.monitors[index])
        let area = monitor.workingFrame
        let horizontal = orientation == .horizontal
        let cut = (horizontal ? area.width : area.height) * (ratio ?? 1) / 2
        for (position, leaf) in leaves.enumerated() {
            let expected: CGRect
            if groups.count == 1 {
                expected = fixture.dwindle.settings.singleWindowFit.frame(in: monitor.borderSafeFillFrame)
            } else {
                let raw = CGRect(
                    x: horizontal && position != 0 ? area.minX + cut : area.minX,
                    y: !horizontal && position != 0 ? area.minY + cut : area.minY,
                    width: horizontal ? (position == 0 ? cut : area.width - cut) : area.width,
                    height: horizontal ? area.height : (position == 0 ? cut : area.height - cut)
                )
                expected = DwindleGapCalculator.applyGaps(
                    nodeRect: raw,
                    tilingArea: area,
                    settings: fixture.dwindle.settings
                )
            }
            XCTAssertEqual(leaf.cachedFrame, expected)
        }
    }

    private func assertDwindleTransferHistoryMembership(_ fixture: Fixture, index: Int, groups: [[WindowToken]]) {
        let workspace = fixture.workspaces[index]
        let leaves = fixture.dwindle.root(for: workspace)?.collectAllLeaves() ?? []
        XCTAssertEqual(leaves.compactMap { $0.tile?.members.map(\.token) }, groups)
        XCTAssertEqual(Set(fixture.manager.entries(in: workspace).map(\.token)), Set(groups.flatMap { $0 }))
        XCTAssertEqual(fixture.dwindle.existingState(for: workspace)?.tileCount, groups.count)
        for token in groups.flatMap({ $0 }) {
            XCTAssertEqual(fixture.manager.workspace(for: token), workspace)
            XCTAssertNotNil(fixture.dwindle.findNode(for: token, in: workspace))
        }
    }

    private struct DwindleTransferHistoryRefreshBlocker {
        let task: Task<Void, Never>
        let completion: AsyncStream<Void>.Continuation
    }

    private func blockDwindleTransferHistoryRefreshes(_ fixture: Fixture) -> DwindleTransferHistoryRefreshBlocker {
        let (events, completion) = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            var iterator = events.makeAsyncIterator()
            _ = await iterator.next()
        }
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = task
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout, reason: .layoutCommand, affectedWorkspaceIds: Set(fixture.workspaces)
        )
        fixture.controller.hasStartedServices = true
        return DwindleTransferHistoryRefreshBlocker(task: task, completion: completion)
    }

    private func finishDwindleTransferHistoryRefreshes(
        _ fixture: Fixture,
        _ blocker: DwindleTransferHistoryRefreshBlocker
    ) {
        blocker.completion.finish()
        blocker.task.cancel()
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = nil
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = nil
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
    }
}
