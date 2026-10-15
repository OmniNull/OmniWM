// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class NiriGatherPlanTests: XCTestCase {
    private let geometry = NiriSizingGeometry(
        workingFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
        gaps: 10,
        orientation: .horizontal
    )

    private let firstSource = WorkspaceDescriptor.ID()
    private let secondSource = WorkspaceDescriptor.ID()
    private let destination = WorkspaceDescriptor.ID()

    private func token(_ id: Int) -> WindowToken {
        WindowToken(pid: 72_000, windowId: id)
    }

    @discardableResult
    private func add(
        _ id: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        in engine: NiriLayoutEngine,
        stackingOnto stackTarget: Int? = nil,
        minHeight: CGFloat = 1
    ) -> NiriWindow {
        let node = engine.addWindow(token: token(id), to: workspaceId, afterSelection: nil)
        engine.updateWindowConstraints(
            for: token(id),
            constraints: WindowSizeConstraints(
                minSize: CGSize(width: 1, height: minHeight),
                maxSize: .zero,
                isFixed: false
            ),
            in: workspaceId,
            motion: .disabled
        )
        if let stackTarget,
           let targetNode = engine.findNode(for: token(stackTarget), in: workspaceId),
           let targetColumn = engine.findColumn(containing: targetNode, in: workspaceId),
           let sourceColumn = engine.findColumn(containing: node, in: workspaceId)
        {
            engine.moveWindowToColumn(node, from: sourceColumn, to: targetColumn, in: workspaceId)
            sourceColumn.remove()
        }
        return node
    }

    private func layout(_ workspaceId: WorkspaceDescriptor.ID, in engine: NiriLayoutEngine) -> [[Int]] {
        engine.columns(in: workspaceId).map { $0.windowNodes.map(\.token.windowId) }
    }

    private func request(
        _ ids: [Int],
        sources: [Int: WorkspaceDescriptor.ID],
        geometry: NiriSizingGeometry? = nil
    ) -> NiriGatherRequest {
        NiriGatherRequest(
            tokens: ids.map(token),
            sourceWorkspaceIds: Dictionary(uniqueKeysWithValues: sources.map { (token($0.key), $0.value) }),
            destinationWorkspaceId: destination,
            geometry: geometry ?? self.geometry
        )
    }

    func testMultiRootGatherPlansAndAppliesExactLeadingColumn() throws {
        let engine = NiriLayoutEngine()
        let firstMoved = add(1, to: firstSource, in: engine)
        let unrelatedFirst = add(11, to: firstSource, in: engine)
        add(2, to: firstSource, in: engine, stackingOnto: 11)
        add(3, to: secondSource, in: engine)
        let unrelatedSecond = add(12, to: secondSource, in: engine)
        let unrelatedDestination = add(13, to: destination, in: engine)
        add(4, to: destination, in: engine)
        XCTAssertEqual(layout(firstSource, in: engine), [[1], [11, 2]])
        XCTAssertEqual(layout(destination, in: engine), [[13], [4]])

        let unrelatedFirstColumn = try XCTUnwrap(engine.findColumn(containing: unrelatedFirst, in: firstSource))
        let unrelatedDestinationColumn = try XCTUnwrap(
            engine.findColumn(containing: unrelatedDestination, in: destination)
        )
        unrelatedDestinationColumn.width = .proportion(0.75)
        let gatherRequest = request(
            [1, 3, 4, 2],
            sources: [1: firstSource, 2: firstSource, 3: secondSource, 4: destination]
        )

        let planning = engine.planGather(
            gatherRequest,
            selections: [
                firstSource: firstMoved.id,
                secondSource: unrelatedSecond.id,
                destination: unrelatedDestination.id
            ]
        )
        guard case let .ready(plan) = planning else {
            return XCTFail("expected a ready plan, got \(planning)")
        }
        XCTAssertEqual(plan.affectedWorkspaceIds, [destination, firstSource, secondSource])
        XCTAssertEqual(plan.movedTokens, [1, 3, 4, 2].map(token))
        XCTAssertEqual(plan.reassignedTokens, [1, 3, 2].map(token))
        XCTAssertEqual(plan.selection(in: firstSource), unrelatedFirst.id)
        XCTAssertEqual(plan.selection(in: secondSource), unrelatedSecond.id)
        XCTAssertEqual(plan.selection(in: destination), unrelatedDestination.id)
        XCTAssertEqual(plan.activeColumnIndex(in: destination), 1)
        XCTAssertEqual(plan.activeColumnIndex(in: firstSource), 0)
        XCTAssertEqual(layout(firstSource, in: engine), [[1], [11, 2]], "planning must not mutate")
        XCTAssertEqual(engine.states.count, 3)

        engine.applyGather(plan)

        XCTAssertEqual(layout(destination, in: engine), [[1, 3, 4, 2], [13]])
        XCTAssertEqual(layout(firstSource, in: engine), [[11]])
        XCTAssertEqual(layout(secondSource, in: engine), [[12]])
        XCTAssertTrue(engine.findNode(for: token(1), in: destination) === firstMoved)
        XCTAssertNil(engine.findNode(for: token(1), in: firstSource))
        XCTAssertNil(engine.findNode(for: token(3), in: secondSource))
        XCTAssertEqual(engine.workspaceIds(containing: token(2)), [destination])
        XCTAssertTrue(engine.findColumn(containing: unrelatedFirst, in: firstSource) === unrelatedFirstColumn)
        XCTAssertTrue(
            engine.findColumn(containing: unrelatedDestination, in: destination) === unrelatedDestinationColumn
        )
        XCTAssertEqual(unrelatedDestinationColumn.width, .proportion(0.75))
        XCTAssertEqual(engine.columns(in: destination).first?.displayMode, .normal)
        XCTAssertEqual(engine.planGather(gatherRequest.reassigned(to: destination), selections: [:]), .unchanged)
    }

    func testPureTabbedLeadingColumnIsReusedReorderedAndAlwaysFits() throws {
        let engine = NiriLayoutEngine()
        add(1, to: destination, in: engine, minHeight: 500)
        add(2, to: destination, in: engine, stackingOnto: 1, minHeight: 500)
        add(13, to: destination, in: engine)
        add(3, to: firstSource, in: engine, minHeight: 500)
        let leading = try XCTUnwrap(engine.columns(in: destination).first)
        leading.displayMode = .tabbed
        leading.width = .proportion(0.4)
        leading.setActiveTileIdx(1)

        let planning = engine.planGather(
            request([2, 3, 1], sources: [1: destination, 2: destination, 3: firstSource]),
            selections: [:]
        )
        guard case let .ready(plan) = planning else { return XCTFail("expected ready, got \(planning)") }
        XCTAssertEqual(plan.reusedColumnId, leading.id)
        XCTAssertEqual(plan.movedTokens, [2, 3, 1].map(token))
        XCTAssertEqual(plan.selection(in: destination), engine.findNode(for: token(2), in: destination)?.id)

        engine.applyGather(plan)
        XCTAssertTrue(engine.columns(in: destination).first === leading)
        XCTAssertEqual(layout(destination, in: engine), [[2, 3, 1], [13]])
        XCTAssertEqual(leading.displayMode, .tabbed)
        XCTAssertEqual(leading.width, .proportion(0.4))
        XCTAssertEqual(leading.activeTileIdx, 0)
        XCTAssertEqual(leading.windowNodes.map(\.isHiddenInTabbedMode), [false, true, true])
        XCTAssertEqual(layout(firstSource, in: engine), [])
    }

    func testEmptyDestinationIsPlannedWithoutAllocationAndSingletonIsolates() throws {
        let engine = NiriLayoutEngine()
        let moved = add(1, to: firstSource, in: engine)
        add(2, to: firstSource, in: engine, stackingOnto: 1)
        let gatherRequest = request([1], sources: [1: firstSource])

        let planning = engine.planGather(gatherRequest, selections: [firstSource: moved.id])
        XCTAssertNil(engine.states[destination], "planning must not allocate destination state")
        guard case let .ready(plan) = planning else { return XCTFail("expected ready, got \(planning)") }
        XCTAssertEqual(plan.affectedWorkspaceIds, [destination, firstSource])
        XCTAssertEqual(plan.selection(in: destination), moved.id)
        XCTAssertEqual(plan.selection(in: firstSource), engine.findNode(for: token(2), in: firstSource)?.id)

        engine.applyGather(plan)
        XCTAssertEqual(layout(destination, in: engine), [[1]])
        XCTAssertEqual(layout(firstSource, in: engine), [[2]])
        XCTAssertEqual(engine.planGather(gatherRequest.reassigned(to: destination), selections: [:]), .unchanged)
    }

    func testFinalAggregateFitUsesDestinationOrientationAndRefusesWithoutMutation() {
        let engine = NiriLayoutEngine()
        add(1, to: firstSource, in: engine, minHeight: 300)
        add(2, to: secondSource, in: engine, minHeight: 300)
        add(3, to: destination, in: engine, minHeight: 300)
        let gatherRequest = request([1, 2, 3], sources: [1: firstSource, 2: secondSource, 3: destination])
        let before = [firstSource, secondSource, destination].map { layout($0, in: engine) }

        XCTAssertEqual(engine.planGather(gatherRequest, selections: [:]), .refused(.doesNotFit))
        XCTAssertEqual([firstSource, secondSource, destination].map { layout($0, in: engine) }, before)
        guard case .ready = engine.planGather(
            request([1, 2], sources: [1: firstSource, 2: secondSource]),
            selections: [:]
        )
        else { return XCTFail("a pair fits on its own") }

        let portrait = NiriSizingGeometry(
            workingFrame: CGRect(x: 0, y: 0, width: 800, height: 1_200),
            gaps: 10,
            orientation: .vertical
        )
        for id in [1, 2, 3] {
            engine.updateWindowConstraints(
                for: token(id),
                constraints: WindowSizeConstraints(
                    minSize: CGSize(width: 300, height: 1),
                    maxSize: .zero,
                    isFixed: false
                ),
                in: id == 1 ? firstSource : id == 2 ? secondSource : destination,
                motion: .disabled
            )
        }
        let sources = [1: firstSource, 2: secondSource, 3: destination]
        guard case .ready = engine.planGather(request([1, 2, 3], sources: sources), selections: [:]) else {
            return XCTFail("narrow minimum widths fit a horizontal destination column")
        }
        XCTAssertEqual(
            engine.planGather(request([1, 2, 3], sources: sources, geometry: portrait), selections: [:]),
            .refused(.doesNotFit)
        )
    }

    func testConflictsAndEngineFullscreenRefuseEveryOffendingWindow() {
        let engine = NiriLayoutEngine()
        add(1, to: firstSource, in: engine)
        add(2, to: secondSource, in: engine)
        add(3, to: destination, in: engine)
        _ = engine.addWindow(token: token(1), to: destination, afterSelection: nil)
        engine.findNode(for: token(2), in: secondSource)?.sizingMode = .fullscreen

        XCTAssertEqual(
            engine.planGather(
                request([1, 2, 3, 4], sources: [1: firstSource, 2: secondSource, 3: firstSource, 4: destination]),
                selections: [:]
            ),
            .refused(.windows([
                token(1): .layoutConflict,
                token(2): .layoutFullscreen,
                token(3): .layoutConflict,
                token(4): .layoutConflict
            ]))
        )
        XCTAssertEqual(layout(destination, in: engine), [[3], [1]])
    }

    func testPlanIsAValueThatGoesStaleWhenItsTreeOrSelectionsChange() throws {
        let engine = NiriLayoutEngine()
        add(1, to: firstSource, in: engine)
        let unrelated = add(11, to: firstSource, in: engine)
        add(2, to: destination, in: engine)
        let gatherRequest = request([1, 2], sources: [1: firstSource, 2: destination])
        let accepted = engine.planGather(gatherRequest, selections: [:])
        XCTAssertEqual(engine.planGather(gatherRequest, selections: [:]), accepted)

        XCTAssertNotEqual(engine.planGather(gatherRequest, selections: [firstSource: unrelated.id]), accepted)
        let column = try XCTUnwrap(engine.findColumn(containing: unrelated, in: firstSource))
        let other = try XCTUnwrap(engine.columns(in: firstSource).first)
        engine.moveWindowToColumn(unrelated, from: column, to: other, in: firstSource)
        column.remove()
        XCTAssertNotEqual(engine.planGather(gatherRequest, selections: [:]), accepted)
    }

    func testEmptiedSourceLosesSelectionAndAllItsColumns() throws {
        let engine = NiriLayoutEngine()
        let first = add(1, to: firstSource, in: engine)
        add(2, to: firstSource, in: engine)
        add(3, to: destination, in: engine)

        let planning = engine.planGather(
            request([1, 2], sources: [1: firstSource, 2: firstSource]),
            selections: [firstSource: first.id]
        )
        guard case let .ready(plan) = planning else { return XCTFail("expected ready, got \(planning)") }
        XCTAssertNil(plan.selection(in: firstSource))
        XCTAssertEqual(plan.activeColumnIndex(in: firstSource), 0)
        XCTAssertEqual(plan.selection(in: destination), first.id)
        XCTAssertEqual(plan.activeColumnIndex(in: destination), 0)

        engine.applyGather(plan)
        XCTAssertEqual(layout(firstSource, in: engine), [])
        XCTAssertEqual(layout(destination, in: engine), [[1, 2], [3]])
        XCTAssertNotNil(engine.states[firstSource])
    }
}

private extension NiriGatherRequest {
    func reassigned(to workspaceId: WorkspaceDescriptor.ID) -> NiriGatherRequest {
        NiriGatherRequest(
            tokens: tokens,
            sourceWorkspaceIds: sourceWorkspaceIds.mapValues { _ in workspaceId },
            destinationWorkspaceId: destinationWorkspaceId,
            geometry: geometry
        )
    }
}
