// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WorldStoreScopeTests: XCTestCase {
    private final class SnapshotRequests {
        var names: [String] = []
    }

    func testTopLevelScopeAsksForItsSnapshotOnlyWhenScopesAreValidated() {
        let validated = SnapshotRequests()
        let unvalidated = SnapshotRequests()

        scope("validated", in: WorldStore(validatesScopes: true), requests: validated)
        scope("unvalidated", in: WorldStore(validatesScopes: false), requests: unvalidated)

        XCTAssertEqual(validated.names, ["validated"])
        XCTAssertEqual(unvalidated.names, [])
    }

    func testNestedScopesAskOnlyAtTheOutermostWhenValidated() {
        let world = WorldStore(validatesScopes: true)
        let requests = SnapshotRequests()

        scope("outer", in: world, requests: requests) {
            self.scope("inner", in: world, requests: requests)
        }

        XCTAssertEqual(requests.names, ["outer"])
    }

    func testNestedScopesAskForNothingWhenNotValidated() {
        let world = WorldStore(validatesScopes: false)
        let requests = SnapshotRequests()

        scope("outer", in: world, requests: requests) {
            self.scope("inner", in: world, requests: requests)
        }

        XCTAssertEqual(requests.names, [])
    }

    func testFullCommitInsideScopesMakesOnlyTheOutermostScopeAsk() {
        let world = WorldStore(validatesScopes: false)
        let requests = SnapshotRequests()

        scope("outer", in: world, requests: requests) {
            self.scope("inner", in: world, requests: requests) {
                self.fullCommit("event", in: world, requests: requests)
            }
        }
        scope("next", in: world, requests: requests)

        let records = world.traceRecords()
        XCTAssertEqual(requests.names, ["event", "event completed", "outer"])
        XCTAssertEqual(records.map(\.event), ["event", "inner", "outer", "next"].map(Self.event))
        XCTAssertTrue(zip(records, records.dropFirst()).allSatisfy { $1.sequence == $0.sequence + 1 })
    }

    func testScopeInsideAFullCommitAsksForNothing() {
        let world = WorldStore(validatesScopes: true)
        let requests = SnapshotRequests()

        world.commit(
            Self.event("event"),
            monitors: [],
            snapshot: { WorldStoreCommitTests.snapshot(focus: world.focus) },
            preMutate: { self.scope("inner", in: world, requests: requests) },
            resolvePlan: { plan, _, _ in plan }
        )

        XCTAssertEqual(requests.names, [])
    }

    func testRequestedValidationMakesAScopeAskUntilItIsWithdrawn() {
        let world = WorldStore(validatesScopes: false)
        let requests = SnapshotRequests()

        world.scopeValidationRequested = true
        scope("requested", in: world, requests: requests)
        world.scopeValidationRequested = false
        scope("withdrawn", in: world, requests: requests)

        XCTAssertEqual(requests.names, ["requested"])
    }

    func testCleanScopeRecordsWhatAFullUserCommandCommitRecords() {
        let clock = Date.distantPast
        let workspaceId = WorkspaceDescriptor.ID()
        let scoped = WorldStore(validatesScopes: true, nowProvider: { clock })
        let committed = WorldStore(validatesScopes: true, nowProvider: { clock })

        scoped.commitScope(
            in: workspaceId,
            label: "parity",
            source: .mouse,
            snapshot: { WorldStoreCommitTests.snapshot(focus: scoped.focus) }
        ) {}
        committed.commit(
            .userCommand(workspaceId: workspaceId, label: "parity", source: .mouse),
            monitors: [],
            snapshot: { WorldStoreCommitTests.snapshot(focus: committed.focus) },
            resolvePlan: { plan, _, _ in plan }
        )

        XCTAssertFalse(scoped.traceRecords().isEmpty)
        XCTAssertEqual(scoped.traceRecords(), committed.traceRecords())
    }

    func testScopeAdvancesTheSequenceBeforeItsBodyAndSanctionsEnginesOnlyInside() {
        let world = WorldStore(validatesScopes: false)
        let entrySeq = world.seq
        var seqInside: UInt64?
        var sanctionedInside = false

        world.commitScope(
            in: nil,
            label: "frame",
            source: .command,
            snapshot: { WorldStoreCommitTests.snapshot(focus: world.focus) }
        ) {
            seqInside = world.seq
            sanctionedInside = world.isEngineMutationSanctioned
        }

        XCTAssertEqual(seqInside, entrySeq + 1)
        XCTAssertEqual(world.seq, entrySeq + 1)
        XCTAssertTrue(sanctionedInside)
        XCTAssertFalse(world.isEngineMutationSanctioned)
    }

    func testEnclosingCommitIsCurrentAgainAfterANestedScope() {
        let world = WorldStore(validatesScopes: false)
        let recorder = InteractionMonitorWriteRecorder.shared
        let enclosing = Self.event("enclosing")
        recorder.reset()

        world.commit(
            enclosing,
            monitors: [],
            snapshot: { WorldStoreCommitTests.snapshot(focus: world.focus) },
            preMutate: {
                self.scope("nested", in: world, requests: SnapshotRequests())
                world.updateFocus { $0.interactionMonitorId = Monitor.ID(displayId: 1) }
            },
            resolvePlan: { plan, _, _ in plan }
        )

        XCTAssertTrue(recorder.dump().contains(enclosing.summary))
        XCTAssertFalse(recorder.dump().contains(Self.event("nested").summary))
    }

    private static func event(_ label: String) -> WMEvent {
        .userCommand(workspaceId: nil, label: label, source: .command)
    }

    private func scope(
        _ label: String,
        in world: WorldStore,
        requests: SnapshotRequests,
        _ body: () -> Void = {}
    ) {
        world.commitScope(
            in: nil,
            label: label,
            source: .command,
            snapshot: {
                requests.names.append(label)
                return WorldStoreCommitTests.snapshot(focus: world.focus)
            },
            body
        )
    }

    private func fullCommit(_ label: String, in world: WorldStore, requests: SnapshotRequests) {
        world.commit(
            Self.event(label),
            monitors: [],
            snapshot: {
                requests.names.append(label)
                return WorldStoreCommitTests.snapshot(focus: world.focus)
            },
            completeSnapshot: { _ in requests.names.append("\(label) completed") },
            resolvePlan: { plan, _, _ in plan }
        )
    }
}
