// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class NiriSingleWindowOverrideTransitionTests: NiriInteractionTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let survivor: NiriWindow
        let neighbor: NiriWindow
        let column: NiriContainer
    }

    private let customFit = SingleWindowFit(mode: .custom, width: 600, height: 500)
    private let customFrame = CGRect(x: 500, y: 200, width: 600, height: 500)

    func testSimpleRemovalRestoresCustomFitWithoutDiscardingDurableWidth() throws {
        let fixture = try makePair()
        resize(fixture.column, in: fixture)

        fixture.engine.removeWindow(token: fixture.neighbor.token, in: fixture.workspaceId)

        XCTAssertFalse(fixture.column.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(fixture.column.width, .fixed(900))
        XCTAssertEqual(layout(fixture.engine, in: fixture.workspaceId)[fixture.survivor.token], customFrame)
    }

    func testBatchRemovalRestoresCustomFitAfterVerticalHeightResize() throws {
        let fixture = try makePair()
        resize(fixture.column, pixels: 700, orientation: .vertical, in: fixture)
        XCTAssertTrue(fixture.column.hasManualSingleWindowHeightOverride)
        var state = ViewportState()

        let result = fixture.engine.removeWindows(
            [fixture.neighbor.token],
            context: context(fixture.workspaceId, orientation: .vertical),
            state: &state,
            selectedNodeId: fixture.survivor.id,
            removedNodeIds: []
        )

        XCTAssertEqual(result.removedTokens, [fixture.neighbor.token])
        XCTAssertFalse(fixture.column.hasManualSingleWindowHeightOverride)
        XCTAssertEqual(fixture.column.height, .fixed(700))
        let frames = fixture.engine.calculateLayout(
            state: state,
            workspaceId: fixture.workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )
        XCTAssertEqual(frames[fixture.survivor.token], customFrame)
    }

    func testContainerPrimarySpanRemovalPreservesManualWidth() throws {
        let fixture = try makePair(fit: SingleWindowFit(mode: .containerPrimarySpan))
        resize(fixture.column, in: fixture)

        _ = removeWindows([fixture.neighbor.token], from: fixture.engine, in: fixture.workspaceId)

        XCTAssertTrue(fixture.column.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(fixture.column.width, .fixed(900))
        let frame = try XCTUnwrap(layout(fixture.engine, in: fixture.workspaceId)[fixture.survivor.token])
        XCTAssertEqual(frame.width, 900, accuracy: 0.001)
    }

    func testRemovalUsesMonitorFitInsteadOfGlobalContainerPrimarySpan() throws {
        let fixture = try makePair(fit: SingleWindowFit(mode: .containerPrimarySpan))
        let monitor = Monitor(
            id: Monitor.ID(displayId: 681),
            displayId: 681,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Single-window transition display"
        )
        _ = fixture.engine.ensureMonitor(for: monitor.id, monitor: monitor, orientation: .horizontal)
        let global = fixture.engine.globalResolvedSettings()
        fixture.engine.updateMonitorSettings(
            ResolvedNiriSettings(
                visibleContainerCount: global.visibleContainerCount,
                defaultContainerPrimarySpan: global.defaultContainerPrimarySpan,
                centerFocusedColumn: global.centerFocusedColumn,
                alwaysCenterSingleColumn: global.alwaysCenterSingleColumn,
                singleWindowFit: customFit,
                infiniteLoop: global.infiniteLoop
            ),
            for: monitor.id
        )
        fixture.engine.moveWorkspace(fixture.workspaceId, to: monitor.id, monitor: monitor)
        resize(fixture.column, in: fixture)

        fixture.engine.removeWindow(token: fixture.neighbor.token, in: fixture.workspaceId)

        XCTAssertFalse(fixture.column.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(layout(fixture.engine, in: fixture.workspaceId)[fixture.survivor.token], customFrame)
    }

    func testSoloResizeThenNeighborOpenAndCloseRestoresCustomFit() throws {
        let engine = NiriLayoutEngine()
        engine.singleWindowFit = customFit
        let workspaceId = WorkspaceDescriptor.ID()
        let survivor = addWindow(engine, pid: 6_811, to: workspaceId)
        let column = try XCTUnwrap(engine.column(of: survivor))
        var state = ViewportState()
        engine.setContainerPrimarySpan(
            column,
            change: .setFixed(900),
            context: context(workspaceId),
            state: &state
        )
        let resizedFrame = try XCTUnwrap(layout(engine, in: workspaceId)[survivor.token])
        XCTAssertEqual(resizedFrame.width, 900, accuracy: 0.001)
        let neighbor = addWindow(engine, pid: 6_812, to: workspaceId, after: survivor)

        engine.removeWindow(token: neighbor.token, in: workspaceId)

        XCTAssertFalse(column.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(layout(engine, in: workspaceId)[survivor.token], customFrame)
    }

    func testRemovingExcludedNeighborPreservesExistingSoloResize() throws {
        let fixture = try makePair()
        fixture.engine.setProjectionExclusions([fixture.neighbor.token], in: fixture.workspaceId)
        resize(fixture.column, in: fixture)
        let before = try XCTUnwrap(layout(fixture.engine, in: fixture.workspaceId)[fixture.survivor.token])
        XCTAssertEqual(before.width, 900, accuracy: 0.001)

        fixture.engine.removeWindow(token: fixture.neighbor.token, in: fixture.workspaceId)

        XCTAssertTrue(fixture.column.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(layout(fixture.engine, in: fixture.workspaceId)[fixture.survivor.token], before)
    }

    func testWindowTransferRestoresSourceFitAndPreservesDestinationSizingAndIdentity() throws {
        let fixture = try makePair()
        let neighborColumn = try XCTUnwrap(fixture.engine.column(of: fixture.neighbor))
        resize(fixture.column, in: fixture)
        resize(neighborColumn, pixels: 800, in: fixture)
        let targetWorkspace = WorkspaceDescriptor.ID()
        var sourceState = ViewportState()
        var targetState = ViewportState()

        let result = fixture.engine.moveWindowToWorkspace(
            fixture.neighbor,
            from: fixture.workspaceId,
            to: targetWorkspace,
            sourceState: &sourceState,
            targetState: &targetState
        )

        XCTAssertEqual(result?.movedToken, fixture.neighbor.token)
        XCTAssertFalse(fixture.column.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(fixture.column.width, .fixed(900))
        XCTAssertEqual(layout(fixture.engine, in: fixture.workspaceId)[fixture.survivor.token], customFrame)
        XCTAssertTrue(fixture.engine.findNode(for: fixture.neighbor.token, in: targetWorkspace) === fixture.neighbor)
        let targetColumn = try XCTUnwrap(fixture.engine.column(of: fixture.neighbor))
        XCTAssertEqual(targetColumn.width, .fixed(800))
        XCTAssertTrue(targetColumn.hasManualSingleWindowWidthOverride)
        let targetFrame = try XCTUnwrap(layout(fixture.engine, in: targetWorkspace)[fixture.neighbor.token])
        XCTAssertEqual(targetFrame.width, 800, accuracy: 0.001)
    }

    func testColumnTransferRestoresSourceFitAndPreservesDestinationColumnIdentity() throws {
        let fixture = try makePair()
        let neighborColumn = try XCTUnwrap(fixture.engine.column(of: fixture.neighbor))
        resize(fixture.column, in: fixture)
        resize(neighborColumn, pixels: 800, in: fixture)
        let targetWorkspace = WorkspaceDescriptor.ID()
        var sourceState = ViewportState()
        var targetState = ViewportState()

        let result = fixture.engine.moveColumnToWorkspace(
            neighborColumn,
            from: fixture.workspaceId,
            to: NiriWorkspaceDestination(workspaceId: targetWorkspace, orientation: .horizontal),
            sourceState: &sourceState,
            targetState: &targetState
        )

        XCTAssertEqual(result?.movedToken, fixture.neighbor.token)
        XCTAssertFalse(fixture.column.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(fixture.column.width, .fixed(900))
        XCTAssertEqual(layout(fixture.engine, in: fixture.workspaceId)[fixture.survivor.token], customFrame)
        XCTAssertTrue(fixture.engine.findNode(for: fixture.neighbor.token, in: targetWorkspace) === fixture.neighbor)
        XCTAssertTrue(fixture.engine.columns(in: targetWorkspace).first === neighborColumn)
        XCTAssertEqual(neighborColumn.width, .fixed(800))
        XCTAssertTrue(neighborColumn.hasManualSingleWindowWidthOverride)
        let targetFrame = try XCTUnwrap(layout(fixture.engine, in: targetWorkspace)[fixture.neighbor.token])
        XCTAssertEqual(targetFrame.width, 800, accuracy: 0.001)
    }

    func testCustomFitAfterRemovalHonorsSurvivorMinimumSize() throws {
        let fixture = try makePair()
        fixture.engine.updateWindowConstraints(
            for: fixture.survivor.token,
            constraints: WindowSizeConstraints(
                minSize: CGSize(width: 800, height: 550),
                maxSize: .zero,
                isFixed: false
            ),
            in: fixture.workspaceId,
            motion: .disabled
        )
        resize(fixture.column, in: fixture)

        _ = removeWindows([fixture.neighbor.token], from: fixture.engine, in: fixture.workspaceId)

        XCTAssertFalse(fixture.column.hasManualSingleWindowWidthOverride)
        let frame = try XCTUnwrap(layout(fixture.engine, in: fixture.workspaceId)[fixture.survivor.token])
        XCTAssertEqual(frame, CGRect(x: 400, y: 175, width: 800, height: 550))
    }

    private func makePair(fit: SingleWindowFit? = nil) throws -> Fixture {
        let engine = NiriLayoutEngine()
        engine.singleWindowFit = fit ?? customFit
        let workspaceId = WorkspaceDescriptor.ID()
        let survivor = addWindow(engine, pid: 6_813, to: workspaceId)
        let neighbor = addWindow(engine, pid: 6_814, to: workspaceId, after: survivor)
        return Fixture(
            engine: engine,
            workspaceId: workspaceId,
            survivor: survivor,
            neighbor: neighbor,
            column: try XCTUnwrap(engine.column(of: survivor))
        )
    }

    private func resize(
        _ column: NiriContainer,
        pixels: CGFloat = 900,
        orientation: Monitor.Orientation = .horizontal,
        in fixture: Fixture
    ) {
        var state = ViewportState()
        fixture.engine.setContainerPrimarySpan(
            column,
            change: .setFixed(pixels),
            context: context(fixture.workspaceId, orientation: orientation),
            state: &state
        )
    }

    private func context(
        _ workspaceId: WorkspaceDescriptor.ID,
        orientation: Monitor.Orientation = .horizontal
    ) -> NiriInteractionContext {
        .init(
            workspaceId: workspaceId,
            motion: .disabled,
            workingFrame: workingFrame,
            gaps: 0,
            orientation: orientation
        )
    }
}
