// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriGatherPublicationTests: XCTestCase {
    private func makeFixture(displayId: UInt32) throws -> NiriGatherFixture {
        try NiriGatherFixture(
            prefix: "OmniWMNiriGatherPublication",
            monitors: [NiriGatherFixture.monitor(displayId: displayId)],
            workspaces: [.init(name: "1"), .init(name: "2"), .init(name: "3")]
        )
    }

    func testMultiRootGatherPublishesOneCompleteCommit() throws {
        let fixture = try makeFixture(displayId: 73_101)
        let manager = fixture.manager
        fixture.add([1, 11, 2], to: fixture.firstSource)
        fixture.add([3, 12], to: fixture.secondSource)
        fixture.add([13, 4], to: fixture.destination)
        _ = manager.rememberFocus(fixture.token(1), in: fixture.firstSource)
        _ = manager.rememberFocus(fixture.token(3), in: fixture.secondSource)
        _ = manager.beginManagedFocusRequest(
            fixture.token(12),
            in: fixture.secondSource,
            onMonitor: fixture.monitor.id,
            requestId: 41
        )
        let pendingBefore = manager.focusSessionSnapshot.pendingManagedFocus
        XCTAssertEqual(pendingBefore.token, fixture.token(12))
        manager.withNiriViewportState(for: fixture.firstSource) { $0.selectedNodeId = fixture.node(
            1,
            in: fixture.firstSource
        )?.id }

        let targets = [1, 3, 4, 2]
        let planning = manager.planNiriGather(fixture.request(targets))
        guard case let .ready(plan) = planning else { return XCTFail("expected ready, got \(planning)") }

        var observedCallbacks: [WorkspaceDescriptor.ID?] = []
        let previousObserver = manager.onRuntimeInvalidation
        manager.onRuntimeInvalidation = { workspaceId, domains, scope in
            observedCallbacks.append(workspaceId)
            for id in targets {
                XCTAssertEqual(manager.workspace(for: fixture.token(id)), fixture.destination)
                XCTAssertNotNil(fixture.node(id, in: fixture.destination))
            }
            XCTAssertEqual(fixture.layout(fixture.destination).first, targets)
            XCTAssertNil(manager.lastFocusedToken(in: fixture.firstSource))
            previousObserver?(workspaceId, domains, scope)
        }
        let sequence = fixture.lastTraceSequence()

        XCTAssertTrue(manager.commitNiriGather(plan))

        let lines = fixture.traceLines(after: sequence)
        XCTAssertEqual(lines.count, 1, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.first?.contains("event=user_command label=niri_gather") == true, lines.joined())
        XCTAssertFalse(lines.first?.contains("violations=") == true, lines.joined())
        XCTAssertEqual(
            Set(observedCallbacks.compactMap(\.self)),
            [fixture.destination, fixture.firstSource, fixture.secondSource]
        )

        XCTAssertEqual(fixture.layout(fixture.destination), [[1, 3, 4, 2], [13]])
        XCTAssertEqual(fixture.layout(fixture.firstSource), [[11]])
        XCTAssertEqual(fixture.layout(fixture.secondSource), [[12]])
        for (tileIndex, id) in targets.enumerated() {
            let entry = try XCTUnwrap(manager.entry(for: fixture.token(id)))
            XCTAssertEqual(entry.workspaceId, fixture.destination)
            XCTAssertEqual(entry.observedState.workspaceId, fixture.destination)
            XCTAssertEqual(entry.desiredState.workspaceId, fixture.destination)
            XCTAssertEqual(entry.observedState.monitorId, fixture.monitor.id)
            XCTAssertEqual(entry.desiredState.monitorId, fixture.monitor.id)
            XCTAssertEqual(entry.restoreIntent?.workspaceId, fixture.destination)
            XCTAssertEqual(entry.restoreIntent?.niriPlacement?.columnIndex, 0)
            XCTAssertEqual(entry.restoreIntent?.niriPlacement?.tileIndex, tileIndex)
        }
        XCTAssertNil(manager.lastFocusedToken(in: fixture.firstSource))
        XCTAssertEqual(manager.lastFocusedToken(in: fixture.secondSource), fixture.token(12))
        XCTAssertEqual(manager.focusSessionSnapshot.pendingManagedFocus, pendingBefore)
        XCTAssertEqual(
            manager.niriViewportState(for: fixture.firstSource).selectedNodeId,
            fixture.node(11, in: fixture.firstSource)?.id
        )
        XCTAssertEqual(manager.niriViewportState(for: fixture.firstSource).activeColumnIndex, 0)
        XCTAssertEqual(
            manager.niriViewportState(for: fixture.destination).selectedNodeId,
            plan.selection(in: fixture.destination)
        )
        XCTAssertEqual(manager.planNiriGather(fixture.request(targets)), .unchanged)
    }

    func testStalePlansAreRefusedBeforeAnyPublication() throws {
        let fixture = try makeFixture(displayId: 73_102)
        let manager = fixture.manager
        fixture.add([1, 11], to: fixture.firstSource)
        fixture.add([2], to: fixture.secondSource)
        fixture.add([13], to: fixture.destination)
        guard case let .ready(treePlan) = manager.planNiriGather(fixture.request([1, 2])) else {
            return XCTFail("expected ready plan")
        }

        manager.withEngineMutationScope {
            let unrelated = fixture.node(11, in: fixture.firstSource)!
            let column = fixture.engine.findColumn(containing: unrelated, in: fixture.firstSource)!
            let leading = fixture.engine.columns(in: fixture.firstSource)[0]
            fixture.engine.moveWindowToColumn(unrelated, from: column, to: leading, in: fixture.firstSource)
            column.remove()
        }
        guard case let .ready(membershipPlan) = manager.planNiriGather(fixture.request([1, 2])) else {
            return XCTFail("expected ready plan")
        }
        manager.setWorkspace(for: fixture.token(2), to: fixture.firstSource)

        let snapshot = Snapshot(fixture)
        XCTAssertFalse(manager.commitNiriGather(treePlan))
        XCTAssertFalse(manager.commitNiriGather(membershipPlan))
        XCTAssertEqual(Snapshot(fixture), snapshot)
    }

    func testEmptyDestinationIsPlannedWithoutAllocation() throws {
        let fixture = try makeFixture(displayId: 73_103)
        let manager = fixture.manager
        fixture.add([1, 2], to: fixture.firstSource)
        XCTAssertEqual(fixture.layout(fixture.destination), [])
        let engineStates = fixture.engine.states.count

        let planning = manager.planNiriGather(fixture.request([2, 1]))
        XCTAssertEqual(fixture.engine.states.count, engineStates)
        guard case let .ready(plan) = planning else { return XCTFail("expected ready, got \(planning)") }
        XCTAssertTrue(manager.commitNiriGather(plan))

        XCTAssertEqual(fixture.layout(fixture.destination), [[2, 1]])
        XCTAssertEqual(fixture.layout(fixture.firstSource), [])
        XCTAssertNil(manager.niriViewportState(for: fixture.firstSource).selectedNodeId)
        XCTAssertEqual(
            manager.niriViewportState(for: fixture.destination).selectedNodeId,
            fixture.node(2, in: fixture.destination)?.id
        )
    }

    @MainActor
    private struct Snapshot: Equatable {
        let worldSeq: UInt64
        let trace: String
        let layouts: [[[Int]]]
        let workspaces: [WorkspaceDescriptor.ID?]
        let focus: FocusSessionSnapshot
        let viewports: [WorkspaceDescriptor.ID: ViewportState]
        let engineStates: Int

        init(_ fixture: NiriGatherFixture) {
            let workspaceIds = [fixture.firstSource, fixture.secondSource, fixture.destination]
            worldSeq = fixture.manager.worldSeq
            trace = fixture.manager.reconcileTraceDump()
            layouts = workspaceIds.map(fixture.layout)
            workspaces = [1, 2, 11, 13].map { fixture.manager.workspace(for: fixture.token($0)) }
            focus = fixture.manager.focusSessionSnapshot
            viewports = fixture.manager.recordedViewportStates
            engineStates = fixture.engine.states.count
        }
    }
}

private extension NiriGatherFixture {
    var firstSource: WorkspaceDescriptor.ID {
        workspace("1")
    }

    var secondSource: WorkspaceDescriptor.ID {
        workspace("2")
    }

    var destination: WorkspaceDescriptor.ID {
        workspace("3")
    }

    var monitor: Monitor {
        monitors[0]
    }

    func request(_ ids: [Int]) -> NiriGatherRequest {
        request(ids, into: destination)
    }
}
