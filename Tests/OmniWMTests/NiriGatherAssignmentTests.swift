// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriGatherAssignmentTests: XCTestCase {
    private let firstSource = WorkspaceDescriptor.ID()
    private let secondSource = WorkspaceDescriptor.ID()
    private let destination = WorkspaceDescriptor.ID()
    private let destinationMonitor = Monitor.ID(displayId: 71_901)
    private let firstToken = WindowToken(pid: 71_901, windowId: 1)
    private let secondToken = WindowToken(pid: 71_902, windowId: 2)
    private let residentToken = WindowToken(pid: 71_903, windowId: 3)
    private let unrelatedToken = WindowToken(pid: 71_904, windowId: 4)

    func testFoldedAssignmentsMatchSequentialWorkspaceAssignedReduction() throws {
        let entries = [
            entry(firstToken, in: firstSource),
            entry(residentToken, in: destination),
            entry(secondToken, in: secondSource)
        ]
        var focus = FocusSessionSnapshot()
        focus.lastFocusedByWorkspace = [firstSource: firstToken, secondSource: secondToken]
        focus.lastTiledFocusedByWorkspace = [firstSource: firstToken, secondSource: secondToken]
        focus.lastFocusedByWorkspace[destination] = residentToken
        focus.pendingManagedFocus = PendingManagedFocusSnapshot(
            token: unrelatedToken,
            workspaceId: firstSource,
            monitorId: nil,
            requestId: 11
        )

        let plan = StateReducer.gatherAssignments(
            entries,
            to: destination,
            monitorId: destinationMonitor,
            focusSession: focus
        )

        var sequentialFocus = focus
        var sequentialPatches: [StateReducer.GatherAssignmentPatch] = []
        for entry in entries where entry.workspaceId != destination {
            let reduced = StateReducer.reduce(
                event: .workspaceAssigned(
                    token: entry.token,
                    from: entry.workspaceId,
                    to: destination,
                    monitorId: destinationMonitor,
                    source: .workspaceManager
                ),
                existingEntry: entry,
                currentSnapshot: snapshot(focus: sequentialFocus),
                monitors: []
            )
            sequentialFocus = reduced.focusSession ?? sequentialFocus
            sequentialPatches.append(
                .init(
                    token: entry.token,
                    sourceWorkspaceId: entry.workspaceId,
                    observedState: try XCTUnwrap(reduced.observedState),
                    desiredState: try XCTUnwrap(reduced.desiredState)
                )
            )
        }

        XCTAssertEqual(plan.patches, sequentialPatches)
        XCTAssertEqual(plan.patches.map(\.token), [firstToken, secondToken])
        XCTAssertEqual(plan.focusSession, sequentialFocus)
        XCTAssertEqual(plan.focusSession?.lastFocusedByWorkspace, [destination: residentToken])
        XCTAssertEqual(plan.focusSession?.lastTiledFocusedByWorkspace, [:])
        XCTAssertEqual(plan.focusSession?.pendingManagedFocus.token, unrelatedToken)
        XCTAssertEqual(plan.focusSession?.pendingManagedFocus.requestId, 11)

        let lastPatchFromOriginal = StateReducer.reassigningFocusState(
            from: focus,
            token: secondToken,
            sourceWorkspaceId: secondSource,
            workspaceId: destination
        )
        XCTAssertEqual(lastPatchFromOriginal?.lastFocusedByWorkspace[firstSource], firstToken)
        XCTAssertNotEqual(lastPatchFromOriginal, plan.focusSession)
    }

    func testFoldClearsMovedPendingFocusAndLeavesSatisfiedRequestsUnchanged() {
        let entries = [entry(firstToken, in: firstSource), entry(secondToken, in: secondSource)]
        var focus = FocusSessionSnapshot()
        focus.pendingManagedFocus = PendingManagedFocusSnapshot(
            token: secondToken,
            workspaceId: secondSource,
            monitorId: nil,
            requestId: 12
        )
        focus.lastFloatingFocusedByWorkspace = [firstSource: firstToken]

        let plan = StateReducer.gatherAssignments(
            entries,
            to: destination,
            monitorId: destinationMonitor,
            focusSession: focus
        )
        XCTAssertEqual(plan.focusSession?.pendingManagedFocus, .empty)
        XCTAssertEqual(plan.focusSession?.lastFloatingFocusedByWorkspace, [:])
        XCTAssertEqual(plan.patches.map(\.desiredState.monitorId), [destinationMonitor, destinationMonitor])
        XCTAssertEqual(plan.patches.map(\.observedState.workspaceId), [destination, destination])

        let satisfied = StateReducer.gatherAssignments(
            [entry(residentToken, in: destination)],
            to: destination,
            monitorId: destinationMonitor,
            focusSession: focus
        )
        XCTAssertEqual(satisfied, StateReducer.GatherAssignmentPlan())
    }

    private func entry(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> WindowState {
        var state = WindowState(
            token: token,
            axRef: WindowAdmissionTestSupport.axRef(for: token),
            workspaceId: workspaceId,
            mode: .tiling,
            managedReplacementMetadata: nil,
            ruleEffects: .none,
            admissionHints: .none
        )
        state.observedState.isMinimized = false
        state.observedState.monitorId = Monitor.ID(displayId: 71_900)
        state.desiredState.monitorId = Monitor.ID(displayId: 71_900)
        return state
    }

    private func snapshot(focus: FocusSessionSnapshot) -> ReconcileSnapshot {
        ReconcileSnapshot(
            topologyProfile: TopologyProfile(sortedMonitors: []),
            focusSession: focus,
            windows: [],
            viewports: [:],
            layouts: [:]
        )
    }
}
