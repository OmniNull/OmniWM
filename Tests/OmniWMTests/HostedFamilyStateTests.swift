// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class HostedFamilyStateTests: XCTestCase {
    func testWorkspaceAssignmentPublishesCompleteFamilyOnSameAndDifferentMonitor() throws {
        let fixture = try HostedFamilyStateFixture()
        defer { fixture.close() }
        let manager = fixture.manager
        for token in fixture.family {
            XCTAssertEqual(manager.hostedFamilyRoot(for: token), fixture.main)
            XCTAssertEqual(manager.hostedFamilyTokens(for: token), fixture.family)
        }
        XCTAssertNil(manager.hostedFamilyRoot(for: fixture.external))
        XCTAssertEqual(manager.hostedFamilyTokens(for: fixture.external), [])
        XCTAssertEqual(manager.hostedFamilyTokens(for: fixture.independent), [fixture.independent])
        let independent = try fixture.entry(fixture.independent)
        let external = try fixture.entry(fixture.external)
        for destination in [fixture.destination, fixture.otherMonitorDestination] {
            let entries = try fixture.family.map(fixture.entry)
            let source = try XCTUnwrap(entries.first?.workspaceId)
            _ = manager.rememberFocus(fixture.utility, in: source)
            let expected = StateReducer.gatherAssignments(
                entries, to: destination, monitorId: manager.monitorId(for: destination),
                focusSession: manager.focusSessionSnapshot
            )
            XCTAssertNil(fixture.base.controller.intentLedger.activeManagedRequest)
            let sequence = manager.worldSeq
            let traceSequence = fixture.base.lastTraceSequence()
            var publications: [[WindowState]] = []
            let previous = manager.onRuntimeInvalidation
            manager.onRuntimeInvalidation = { _, _, _ in
                publications.append(fixture.family.compactMap { manager.entry(for: $0) })
            }
            manager.setWorkspace(for: fixture.main, to: destination)
            manager.onRuntimeInvalidation = previous
            let structuralCommitCount: UInt64 = 1
            let invalidationCount = UInt64(Set([source, destination]).count)
            XCTAssertEqual(manager.worldSeq, sequence + structuralCommitCount + invalidationCount)
            XCTAssertEqual(fixture.base.traceLines(after: traceSequence).count, Int(structuralCommitCount))
            XCTAssertFalse(publications.isEmpty)
            for publication in publications {
                XCTAssertEqual(publication.map(\.workspaceId), fixture.family.map { _ in destination })
            }
            try assertAssignments(expected, fixture: fixture, destination: destination)
        }
        XCTAssertEqual(try fixture.entry(fixture.independent), independent)
        XCTAssertEqual(try fixture.entry(fixture.external), external)
    }

    func testGatherAssignsFamilyWithoutPackingFloatingChildren() throws {
        let fixture = try HostedFamilyStateFixture()
        defer { fixture.close() }
        let manager = fixture.manager
        _ = manager.rememberFocus(fixture.sheet, in: fixture.source)
        let expected = StateReducer.gatherAssignments(
            try fixture.family.map(fixture.entry), to: fixture.otherMonitorDestination,
            monitorId: fixture.base.monitors[1].id, focusSession: manager.focusSessionSnapshot
        )
        let planning = manager.planNiriGather(fixture.gatherRequest())
        guard case let .ready(plan) = planning else { return XCTFail("Expected a ready gather, got \(planning)") }
        var publications: [[WindowToken]] = []
        let previous = manager.onRuntimeInvalidation
        manager.onRuntimeInvalidation = { _, _, _ in
            publications.append(fixture.family.filter { manager.workspace(for: $0) == fixture.otherMonitorDestination })
        }
        XCTAssertNil(fixture.base.controller.intentLedger.activeManagedRequest)
        let sequence = manager.worldSeq
        let traceSequence = fixture.base.lastTraceSequence()
        XCTAssertTrue(manager.commitNiriGather(plan))
        manager.onRuntimeInvalidation = previous
        let structuralCommitCount: UInt64 = 1
        let batchedInvalidationCount: UInt64 = 1
        XCTAssertEqual(manager.worldSeq, sequence + structuralCommitCount + batchedInvalidationCount)
        XCTAssertEqual(fixture.base.traceLines(after: traceSequence).count, Int(structuralCommitCount))
        XCTAssertFalse(publications.isEmpty)
        XCTAssertTrue(publications.allSatisfy { $0 == fixture.family })
        try assertAssignments(expected, fixture: fixture, destination: fixture.otherMonitorDestination)
        XCTAssertNotNil(fixture.base.engine.findNode(for: fixture.main, in: fixture.otherMonitorDestination))
        for token in [fixture.sheet, fixture.utility] {
            XCTAssertEqual(manager.windowMode(for: token), .floating)
            for workspace in [fixture.source, fixture.otherMonitorDestination] {
                XCTAssertNil(fixture.base.engine.findNode(for: token, in: workspace))
            }
        }
        XCTAssertEqual(manager.workspace(for: fixture.external), fixture.source)
        XCTAssertEqual(manager.workspace(for: fixture.independent), fixture.source)
    }

    func testMinimizationInheritsOnlyMinimizedBitAndRejectsIndependentChildMutation() throws {
        let fixture = try HostedFamilyStateFixture()
        defer { fixture.close() }
        let manager = fixture.manager
        XCTAssertTrue(manager.setWindowNativeWithdrawn(true, token: fixture.utility))
        let geometry = try fixture.family.map { try fixture.entry($0).floatingState }
        for minimized in [true, false] {
            var publications: [[Bool]] = []
            let previous = manager.onRuntimeInvalidation
            manager.onRuntimeInvalidation = { _, _, _ in
                publications.append(fixture.family.compactMap { manager.entry(for: $0)?.observedState.isMinimized })
            }
            XCTAssertTrue(manager.setWindowMinimized(minimized, token: fixture.main))
            manager.onRuntimeInvalidation = previous
            XCTAssertFalse(publications.isEmpty)
            XCTAssertTrue(publications.allSatisfy { $0 == fixture.family.map { _ in minimized } })
            for token in fixture.family {
                let entry = try fixture.entry(token)
                XCTAssertEqual(entry.observedState.isMinimized, minimized)
                XCTAssertEqual(entry.observedState.isNativeWithdrawn, token == fixture.utility)
            }
            let sequence = manager.worldSeq
            XCTAssertFalse(manager.setWindowMinimized(!minimized, token: fixture.sheet))
            XCTAssertFalse(manager.setWindowMinimized(!minimized, token: fixture.utility))
            XCTAssertEqual(manager.worldSeq, sequence)
        }
        XCTAssertEqual(try fixture.family.map { try fixture.entry($0).floatingState }, geometry)
        XCTAssertFalse(try fixture.entry(fixture.independent).observedState.isMinimized)
        XCTAssertFalse(try fixture.entry(fixture.external).observedState.isMinimized)
    }

    func testParentSuppressionReturnsChildFocusChangeAndCompleteSnapshot() throws {
        let fixture = try HostedFamilyStateFixture()
        defer { fixture.close() }
        let manager = fixture.manager
        XCTAssertTrue(manager.setManagedFocus(
            fixture.sheet, in: fixture.source, onMonitor: fixture.base.monitors[0].id
        ))
        XCTAssertEqual(manager.focusSessionSnapshot.nativeFocusOwner, .managed(fixture.sheet))
        let transaction = manager.recordReconcileEvent(.windowMinimizedChanged(
            token: fixture.main, workspaceId: fixture.source, minimized: true, source: .workspaceManager
        ))
        XCTAssertEqual(transaction.plan.focusSession?.nativeFocusOwner, NativeFocusOwner.none)
        XCTAssertEqual(transaction.snapshot.focusSession.nativeFocusOwner, .none)
        XCTAssertEqual(manager.focusSessionSnapshot.nativeFocusOwner, .none)
        for token in fixture.family {
            let snapshot = try XCTUnwrap(transaction.snapshot.windows.first { $0.token == token })
            XCTAssertTrue(snapshot.observedState.isMinimized)
        }
        XCTAssertEqual(transaction.invariantViolations, [])
    }

    func testHiddenStatePreservesChildGeometryAndRejectsStaleIndependentRestore() throws {
        let fixture = try HostedFamilyStateFixture()
        defer { fixture.close() }
        let manager = fixture.manager
        let geometry = try fixture.family.map { try fixture.entry($0).floatingState }
        for reason in [HiddenReason.workspaceInactive, .layoutTransient(.left)] {
            let hidden = try fixture.hidden(fixture.main, reason: reason)
            manager.setHiddenState(hidden, for: fixture.main)
            for token in fixture.family {
                XCTAssertEqual(manager.hiddenState(for: token), try fixture.hidden(token, reason: reason))
                XCTAssertFalse(try fixture.entry(token).observedState.isVisible)
            }
            let sequence = manager.worldSeq
            for token in [fixture.sheet, fixture.utility] {
                manager.setHiddenState(nil, for: token)
                manager.setWorkspace(for: token, to: fixture.destination)
            }
            XCTAssertEqual(manager.worldSeq, sequence)
        }
        manager.setHiddenState(nil, for: fixture.main)
        for token in fixture.family {
            XCTAssertNil(manager.hiddenState(for: token))
            XCTAssertTrue(try fixture.entry(token).observedState.isVisible)
        }
        XCTAssertEqual(try fixture.family.map { try fixture.entry($0).floatingState }, geometry)
        XCTAssertNil(manager.hiddenState(for: fixture.independent))
        XCTAssertNil(manager.hiddenState(for: fixture.external))
    }

    private func assertAssignments(
        _ expected: StateReducer.GatherAssignmentPlan,
        fixture: HostedFamilyStateFixture,
        destination: WorkspaceDescriptor.ID
    ) throws {
        for patch in expected.patches {
            let entry = try fixture.entry(patch.token)
            XCTAssertEqual(entry.workspaceId, destination)
            XCTAssertEqual(entry.observedState, patch.observedState)
            XCTAssertEqual(entry.desiredState, patch.desiredState)
            XCTAssertEqual(entry.restoreIntent?.workspaceId, destination)
        }
        if let focus = expected.focusSession {
            XCTAssertEqual(fixture.manager.focusSessionSnapshot, focus)
        }
    }
}
