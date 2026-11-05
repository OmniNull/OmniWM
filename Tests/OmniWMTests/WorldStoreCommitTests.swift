// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class WorldStoreCommitTests: XCTestCase {
    func testCommitReusesReducerSnapshotWithoutPostReducerMutation() {
        let world = WorldStore()
        var snapshotCount = 0

        let transaction = world.commit(
            .userCommand(workspaceId: nil, label: "projection_test", source: .command),
            monitors: [],
            snapshot: {
                snapshotCount += 1
                return Self.snapshot(focus: world.focus)
            },
            resolvePlan: { plan, _, _ in plan }
        )

        XCTAssertEqual(snapshotCount, 1)
        XCTAssertEqual(transaction.snapshot, Self.snapshot(focus: world.focus))
    }

    func testCommitBuildsCommittedSnapshotAfterResolvedPlanMutation() {
        let world = WorldStore()
        var snapshotCount = 0
        var nextFocus = FocusSessionSnapshot()
        nextFocus.nativeFocusOwner = .external(pid: nil, windowId: nil)

        let transaction = world.commit(
            .userCommand(workspaceId: nil, label: "projection_test", source: .command),
            monitors: [],
            snapshot: {
                snapshotCount += 1
                return Self.snapshot(focus: world.focus)
            },
            resolvePlan: { plan, _, _ in
                var plan = plan
                plan.focusSession = nextFocus
                world.applyFocusSession(nextFocus)
                return plan
            }
        )

        XCTAssertEqual(snapshotCount, 2)
        XCTAssertEqual(transaction.snapshot.focusSession, nextFocus)
    }

    func testCommitBuildsCommittedSnapshotForAfterPlanRemoval() {
        let world = WorldStore()
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 10, windowId: 20)
        let axRef = AXWindowRef(
            element: AXUIElementCreateApplication(token.pid),
            windowId: token.windowId
        )
        _ = world.commit(
            .windowAdmitted(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                mode: .tiling,
                axRef: axRef,
                ruleEffects: .none,
                admissionHints: .none,
                lifetimeAuthority: .axTopLevelInventory,
                adoptNativeFocus: false,
                managedReplacementMetadata: nil,
                source: .workspaceManager
            ),
            monitors: [],
            snapshot: { Self.snapshot(world: world) },
            resolvePlan: { plan, _, _ in plan }
        )
        XCTAssertNotNil(world.windows.entry(for: token))

        var snapshotCount = 0
        var completionCount = 0
        let transaction = world.commit(
            .windowRemoved(
                token: token,
                workspaceId: workspaceId,
                source: .workspaceManager
            ),
            monitors: [],
            snapshot: {
                snapshotCount += 1
                return Self.snapshot(world: world)
            },
            completeSnapshot: { snapshot in
                completionCount += 1
                XCTAssertFalse(snapshot.windows.contains { $0.token == token })
            },
            resolvePlan: { plan, _, _ in plan }
        )

        XCTAssertEqual(snapshotCount, 2)
        XCTAssertEqual(completionCount, 1)
        XCTAssertNil(world.windows.entry(for: token))
        XCTAssertFalse(transaction.snapshot.windows.contains { $0.token == token })
    }

    func testTopLevelInventoryObservationPromotesBeforeOneReducerSnapshot() {
        let world = WorldStore()
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 30, windowId: 40)
        let axRef = AXWindowRef(
            element: AXUIElementCreateApplication(token.pid),
            windowId: token.windowId
        )
        _ = world.commit(
            .windowAdmitted(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                mode: .tiling,
                axRef: axRef,
                ruleEffects: .none,
                admissionHints: .none,
                lifetimeAuthority: .directLifecycle,
                adoptNativeFocus: false,
                managedReplacementMetadata: nil,
                source: .workspaceManager
            ),
            monitors: [],
            snapshot: { Self.snapshot(world: world) },
            resolvePlan: { plan, _, _ in plan }
        )

        var snapshotCount = 0
        let transaction = world.commit(
            .topLevelInventoryObserved(tokens: [token], source: .workspaceManager),
            monitors: [],
            snapshot: {
                snapshotCount += 1
                return Self.snapshot(world: world)
            },
            resolvePlan: { plan, _, _ in plan }
        )

        XCTAssertEqual(snapshotCount, 1)
        XCTAssertTrue(transaction.plan.isEmpty)
        XCTAssertEqual(world.windows.entry(for: token)?.lifetimeAuthority, .axTopLevelInventory)
        XCTAssertEqual(transaction.snapshot.windows.first?.lifetimeAuthority, .axTopLevelInventory)
    }

    func testCommitCompletesOnlySelectedSnapshotAfterMutation() {
        let world = WorldStore()
        var phases: [String] = []
        var nextFocus = FocusSessionSnapshot()
        nextFocus.nativeFocusOwner = .external(pid: nil, windowId: nil)
        let workspaceId = WorkspaceDescriptor.ID()
        let layout = LayoutTopology()

        let transaction = world.commit(
            .userCommand(workspaceId: nil, label: "completion_test", source: .command),
            monitors: [],
            snapshot: {
                phases.append("snapshot")
                return Self.snapshot(focus: world.focus)
            },
            completeSnapshot: { snapshot in
                phases.append("complete")
                XCTAssertEqual(snapshot.focusSession, nextFocus)
                snapshot.layouts[workspaceId] = layout
            },
            resolvePlan: { plan, _, snapshot in
                phases.append("resolve")
                XCTAssertTrue(snapshot.layouts.isEmpty)
                var plan = plan
                plan.focusSession = nextFocus
                world.applyFocusSession(nextFocus)
                return plan
            }
        )

        XCTAssertEqual(phases, ["snapshot", "resolve", "snapshot", "complete"])
        XCTAssertEqual(transaction.snapshot.layouts, [workspaceId: layout])
    }

    func testCommitCompletesReusedSnapshotForNonmutatingPlan() {
        let world = WorldStore()
        var snapshotCount = 0
        var completionCount = 0
        let workspaceId = WorkspaceDescriptor.ID()
        let layout = LayoutTopology()

        let transaction = world.commit(
            .userCommand(workspaceId: nil, label: "completion_test", source: .command),
            monitors: [],
            snapshot: {
                snapshotCount += 1
                return Self.snapshot(focus: world.focus)
            },
            completeSnapshot: { snapshot in
                completionCount += 1
                snapshot.layouts[workspaceId] = layout
            },
            resolvePlan: { plan, _, _ in plan }
        )

        XCTAssertEqual(snapshotCount, 1)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(transaction.snapshot.layouts, [workspaceId: layout])
    }

    func testNestedCommitCompletesSnapshotWithoutInvariantValidation() {
        let world = WorldStore()
        let workspaceId = WorkspaceDescriptor.ID()
        let layout = LayoutTopology()
        var completionCount = 0
        var nestedSnapshot: ReconcileSnapshot?
        let event = WMEvent.userCommand(workspaceId: nil, label: "completion_test", source: .command)

        _ = world.commit(
            event,
            monitors: [],
            snapshot: { Self.snapshot(focus: world.focus) },
            resolvePlan: { plan, _, _ in
                let nested = world.commit(
                    event,
                    monitors: [],
                    snapshot: { Self.snapshot(focus: world.focus) },
                    completeSnapshot: { snapshot in
                        completionCount += 1
                        snapshot.layouts[workspaceId] = layout
                    },
                    resolvePlan: { plan, _, _ in plan }
                )
                nestedSnapshot = nested.snapshot
                return plan
            }
        )

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(nestedSnapshot?.layouts, [workspaceId: layout])
    }

    private static func snapshot(world: WorldStore) -> ReconcileSnapshot {
        snapshot(
            focus: world.focus,
            windows: world.windows.allEntries().map {
                ReconcileWindowSnapshot(
                    token: $0.token,
                    workspaceId: $0.workspaceId,
                    mode: $0.mode,
                    lifecyclePhase: $0.lifecyclePhase,
                    observedState: $0.observedState,
                    desiredState: $0.desiredState,
                    restoreWorkspaceId: $0.restoreIntent?.workspaceId,
                    lifetimeAuthority: $0.lifetimeAuthority
                )
            }
        )
    }

    private static func snapshot(
        focus: FocusSessionSnapshot,
        windows: [ReconcileWindowSnapshot] = []
    ) -> ReconcileSnapshot {
        ReconcileSnapshot(
            topologyProfile: TopologyProfile(sortedMonitors: []),
            focusSession: focus,
            windows: windows
        )
    }
}
