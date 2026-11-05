// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class MonitorRestoreIdentityTests: XCTestCase {
    private let displayUUIDA = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let displayUUIDB = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let displayUUIDC = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"

    func testRestoreAssignmentsFollowUUIDWhenRuntimeIdsSwap() {
        let workspaceA = UUID()
        let workspaceB = UUID()
        let previousA = monitor(id: 2, name: "Identical", uuid: displayUUIDA, x: 0)
        let previousB = monitor(id: 3, name: "Identical", uuid: displayUUIDB, x: 1440)
        let currentA = monitor(id: 3, name: "Identical", uuid: displayUUIDA, x: 0)
        let currentB = monitor(id: 2, name: "Identical", uuid: displayUUIDB, x: 1440)

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: [
                WorkspaceRestoreSnapshot(
                    monitor: MonitorRestoreKey(monitor: previousA),
                    workspaceId: workspaceA
                ),
                WorkspaceRestoreSnapshot(
                    monitor: MonitorRestoreKey(monitor: previousB),
                    workspaceId: workspaceB
                )
            ],
            monitors: [currentA, currentB],
            workspaceExists: { _ in true }
        )

        XCTAssertEqual(assignments[currentA.id], workspaceA)
        XCTAssertEqual(assignments[currentB.id], workspaceB)
    }

    func testRestoreAssignmentPrefersUUIDOrLegacyRuntimeIdentity() {
        for uuidLess in [false, true] {
            let workspace = UUID()
            let previous = monitor(id: 2, name: "Display", uuid: uuidLess ? nil : displayUUIDA, x: 0)
            let recycled = monitor(id: 2, name: "Display", uuid: uuidLess ? nil : displayUUIDB, x: 2000)
            let geometric = monitor(id: 9, name: "Display", uuid: uuidLess ? nil : displayUUIDC, x: 0)
            let assignments = resolveWorkspaceRestoreAssignments(
                snapshots: [WorkspaceRestoreSnapshot(
                    monitor: MonitorRestoreKey(monitor: previous),
                    workspaceId: workspace
                )],
                monitors: [recycled, geometric], workspaceExists: { _ in true }
            )
            XCTAssertEqual(assignments[uuidLess ? recycled.id : geometric.id], workspace)
            XCTAssertNil(assignments[uuidLess ? geometric.id : recycled.id])
        }
    }

    func testDuplicateUUIDsSkipIdentityAndRemainOneToOneByGeometry() {
        let workspaceA = UUID()
        let workspaceB = UUID()
        let previousA = monitor(id: 2, name: "Display", uuid: displayUUIDA, x: 0)
        let previousB = monitor(id: 3, name: "Display", uuid: displayUUIDA, x: 1440)
        let currentA = monitor(id: 8, name: "Display", uuid: displayUUIDA, x: 0)
        let currentB = monitor(id: 9, name: "Display", uuid: displayUUIDA, x: 1440)

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: [
                WorkspaceRestoreSnapshot(
                    monitor: MonitorRestoreKey(monitor: previousA),
                    workspaceId: workspaceA
                ),
                WorkspaceRestoreSnapshot(
                    monitor: MonitorRestoreKey(monitor: previousB),
                    workspaceId: workspaceB
                )
            ],
            monitors: [currentA, currentB],
            workspaceExists: { _ in true }
        )

        XCTAssertEqual(assignments[currentA.id], workspaceA)
        XCTAssertEqual(assignments[currentB.id], workspaceB)
        XCTAssertEqual(Set(assignments.values).count, 2)
    }

    func testRestoreKeysUseStableUUIDIdentity() {
        let first = MonitorRestoreKey(
            monitor: monitor(id: 2, name: "Old", uuid: displayUUIDA, x: 0)
        )
        let second = MonitorRestoreKey(
            monitor: monitor(id: 9, name: "New", uuid: displayUUIDA, x: 2000)
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 1)
    }

    func testDisplayFingerprintRoundTripsUUIDAndDecodesMissingUUID() throws {
        let fingerprint = DisplayFingerprint(
            monitor: monitor(id: 2, name: "Display", uuid: displayUUIDA, x: 0)
        )
        let data = try JSONEncoder().encode(fingerprint)
        let decoded = try JSONDecoder().decode(DisplayFingerprint.self, from: data)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "displayUUID")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(DisplayFingerprint.self, from: legacyData)

        XCTAssertEqual(decoded, fingerprint)
        XCTAssertEqual(decoded.displayUUID, displayUUIDA)
        XCTAssertNil(legacy.displayUUID)
        object["displayUUID"] = "not-a-uuid"
        let malformed = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(DisplayFingerprint.self, from: malformed))
    }

    func testPersistedHydrationResolvesIdentityAndGeometryFallbacks() throws {
        let cases: [(String?, String?, String?, String, Int)] = [
            (displayUUIDA, displayUUIDB, displayUUIDA, "Renamed", 1),
            (nil, nil, nil, "Display", 0),
            (displayUUIDA, displayUUIDB, displayUUIDC, "Display", 1)
        ]
        for (previousUUID, recycledUUID, geometricUUID, geometricName, expectedIndex) in cases {
            let previous = monitor(id: 2, name: "Display", uuid: previousUUID, x: 0)
            let current = [
                monitor(id: 2, name: "Display", uuid: recycledUUID, x: 2000),
                monitor(id: 9, name: geometricName, uuid: geometricUUID, x: 0)
            ]
            let preferredMonitorId = try persistedPreferredMonitor(previous: previous, current: current)
            XCTAssertEqual(preferredMonitorId, current[expectedIndex].id)
        }
    }

    private func monitor(
        id: CGDirectDisplayID,
        name: String,
        uuid: String?,
        x: CGFloat
    ) -> Monitor {
        Monitor(
            id: .init(displayId: id),
            displayId: id,
            frame: CGRect(x: x, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: x, y: 0, width: 1440, height: 900),
            hasNotch: false,
            name: name,
            displayUUID: uuid
        )
    }

    func testPersistedHydrationKeepsItsMatchPrecedence() throws {
        let token = WindowToken(pid: 123, windowId: 456)
        let otherToken = WindowToken(pid: 124, windowId: 457)
        let metadata = ManagedReplacementMetadata(
            bundleId: "com.example.identity",
            workspaceId: UUID(),
            mode: .tiling,
            role: nil,
            subrole: nil,
            title: "Window",
            windowLevel: 0,
            parentWindowId: nil,
            frame: nil
        )
        let workspaceIds = ["hard": UUID(), "hard2": UUID(), "soft": UUID(), "soft2": UUID()]
        func entry(
            _ workspace: String,
            identityOf owner: WindowToken,
            title: String? = nil
        ) throws -> PersistedWindowRestoreEntry {
            try PersistedWindowRestoreEntry(
                key: XCTUnwrap(PersistedWindowRestoreKey(metadata: metadata, title: title)),
                identity: XCTUnwrap(PersistedWindowRestoreIdentity(token: owner, metadata: metadata)),
                restoreIntent: PersistedRestoreIntent(
                    workspaceName: workspace,
                    topologyProfile: TopologyProfile(monitors: []),
                    preferredMonitor: nil,
                    floatingFrame: nil,
                    normalizedFloatingOrigin: nil,
                    restoreToFloating: false,
                    rescueEligible: false
                )
            )
        }
        func restoredWorkspace(
            _ entries: [PersistedWindowRestoreEntry],
            consumed: [PersistedWindowRestoreEntry] = [],
            metadata planned: ManagedReplacementMetadata? = nil
        ) -> String? {
            let plan = PersistedRestorePlanner.plan(PersistedRestorePlanner.Input(
                token: token,
                metadata: planned ?? metadata,
                catalog: PersistedWindowRestoreCatalog(entries: entries),
                consumedEntries: Set(consumed.map(PersistedWindowRestoreConsumptionKey.init(entry:))),
                monitors: [],
                workspaceIdForName: { workspaceIds[$0] }
            ))
            return workspaceIds.first { $0.value == plan?.workspaceId }?.key
        }
        let hard = try entry("hard", identityOf: token)
        let secondHard = try entry("hard2", identityOf: token, title: "Second")
        let soft = try entry("soft", identityOf: otherToken)
        let secondSoft = try entry("soft2", identityOf: WindowToken(pid: 125, windowId: 458))

        XCTAssertEqual(restoredWorkspace([soft, hard]), "hard")
        XCTAssertNil(restoredWorkspace([hard, secondHard]))
        XCTAssertEqual(restoredWorkspace([hard, secondHard], consumed: [hard]), "hard2")
        XCTAssertNil(restoredWorkspace([hard, soft], consumed: [hard]))
        XCTAssertEqual(restoredWorkspace([soft, secondSoft], consumed: [soft]), "soft2")
        XCTAssertNil(restoredWorkspace([soft, secondSoft]))
        var titled = metadata
        titled.title = "Different"
        XCTAssertNil(restoredWorkspace([soft], metadata: titled))
        var bundleless = metadata
        bundleless.bundleId = "   "
        XCTAssertNil(restoredWorkspace([hard, soft], metadata: bundleless))
    }

    private func persistedPreferredMonitor(
        previous: Monitor,
        current: [Monitor]
    ) throws -> Monitor.ID? {
        let workspaceId = UUID()
        let token = WindowToken(pid: 123, windowId: 456)
        let metadata = ManagedReplacementMetadata(
            bundleId: "com.example.identity",
            workspaceId: workspaceId,
            mode: .tiling,
            role: nil,
            subrole: nil,
            title: "Window",
            windowLevel: 0,
            parentWindowId: nil,
            frame: nil
        )
        let entry = PersistedWindowRestoreEntry(
            key: try XCTUnwrap(PersistedWindowRestoreKey(metadata: metadata)),
            identity: nil,
            restoreIntent: PersistedRestoreIntent(
                workspaceName: "1",
                topologyProfile: TopologyProfile(monitors: [previous]),
                preferredMonitor: DisplayFingerprint(monitor: previous),
                floatingFrame: nil,
                normalizedFloatingOrigin: nil,
                restoreToFloating: false,
                rescueEligible: false
            )
        )
        let plan = PersistedRestorePlanner.plan(
            PersistedRestorePlanner.Input(
                token: token,
                metadata: metadata,
                catalog: PersistedWindowRestoreCatalog(entries: [entry]),
                consumedEntries: [],
                monitors: current,
                workspaceIdForName: { $0 == "1" ? workspaceId : nil }
            )
        )
        return try XCTUnwrap(plan).preferredMonitorId
    }
}
