// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class MonitorRankingTests: XCTestCase {
    private let builtIn = MonitorRankingTests.makeMonitor(
        id: 1,
        x: 0,
        name: "Built-in Retina Display",
        uuid: "11111111-1111-1111-1111-111111111111"
    )
    private let dell = MonitorRankingTests.makeMonitor(
        id: 2,
        x: 1440,
        name: "DELL U3423WE",
        uuid: "22222222-2222-2222-2222-222222222222"
    )
    private let lg = MonitorRankingTests.makeMonitor(
        id: 3,
        x: 4880,
        name: "LG HDR 4K",
        uuid: "33333333-3333-3333-3333-333333333333"
    )

    func testEmptyRankingKeepsDefaultOrder() {
        let sorted = Monitor.sortedByPosition([builtIn, dell, lg])
        XCTAssertEqual(
            MonitorRanking.roleOrder(ranking: [], sortedMonitors: sorted).map(\.id),
            MonitorRanking.defaultOrder(sorted).map(\.id)
        )
    }

    func testRankingOrdersConnectedMonitorsThenAppendsTheRest() {
        let sorted = Monitor.sortedByPosition([builtIn, dell, lg])
        let ranking = [OutputId(from: lg), OutputId(from: dell)]

        let order = MonitorRanking.roleOrder(ranking: ranking, sortedMonitors: sorted)

        XCTAssertEqual(order.map(\.displayId), [3, 2, 1])
    }

    func testRankingSkipsDisconnectedEntriesAndDuplicates() {
        let sorted = Monitor.sortedByPosition([builtIn, dell])
        let ranking = [
            OutputId(from: lg),
            OutputId(from: dell),
            OutputId(displayUUID: nil, displayId: nil, name: "dell u3423we"),
            OutputId(from: builtIn)
        ]

        let order = MonitorRanking.roleOrder(ranking: ranking, sortedMonitors: sorted)

        XCTAssertEqual(order.map(\.displayId), [2, 1])
    }

    func testResolveFallsBackToUniqueCaseInsensitiveName() {
        let nameOnly = OutputId(displayUUID: nil, displayId: nil, name: "lg hdr 4k")
        XCTAssertEqual(MonitorRanking.resolve(nameOnly, in: [builtIn, dell, lg])?.displayId, 3)
    }

    func testResolveRejectsAmbiguousNameAndPrefersIdentity() {
        let twin = Self.makeMonitor(id: 4, x: 7440, name: "DELL U3423WE", uuid: "44444444-4444-4444-4444-444444444444")
        let nameOnly = OutputId(displayUUID: nil, displayId: nil, name: "DELL U3423WE")

        XCTAssertNil(MonitorRanking.resolve(nameOnly, in: [builtIn, dell, twin]))
        XCTAssertEqual(MonitorRanking.resolve(OutputId(from: twin), in: [builtIn, dell, twin])?.displayId, 4)
    }

    func testResolveDoesNotFallBackToNameWhenEntryUUIDIsStale() {
        let stale = OutputId(displayUUID: "99999999-9999-9999-9999-999999999999", name: "DELL U3423WE")
        // Rank every display explicitly so the host's main display cannot affect this identity check.
        let ranking = [stale, OutputId(from: lg), OutputId(from: builtIn), OutputId(from: dell)]

        XCTAssertNil(MonitorRanking.resolve(stale, in: [builtIn, dell, lg]))
        XCTAssertEqual(
            MonitorRanking.roleOrder(ranking: ranking, sortedMonitors: [builtIn, dell, lg])
                .map(\.displayId),
            [3, 1, 2]
        )
    }

    func testEffectiveRanksSkipDisconnectedAndDuplicateEntries() {
        let ranking = [OutputId(from: lg), OutputId(from: dell), OutputId(from: dell), OutputId(from: builtIn)]

        XCTAssertEqual(
            MonitorRanking.effectiveRanks(ranking: ranking, monitors: [builtIn, dell]),
            [nil, 0, nil, 1]
        )
        XCTAssertEqual(
            MonitorRanking.effectiveRanks(ranking: ranking, monitors: [builtIn, dell, lg]),
            [0, 1, nil, 2]
        )
    }

    func testMainAndSecondaryFollowRanking() {
        let sorted = Monitor.sortedByPosition([builtIn, dell, lg])
        let ranking = [OutputId(from: lg), OutputId(from: dell), OutputId(from: builtIn)]

        XCTAssertEqual(MonitorDescription.main.resolveMonitor(sortedMonitors: sorted, ranking: ranking)?.displayId, 3)
        XCTAssertEqual(
            MonitorDescription.secondary.resolveMonitor(sortedMonitors: sorted, ranking: ranking)?.displayId,
            2
        )

        XCTAssertEqual(
            MonitorDescription.tertiary.resolveMonitor(sortedMonitors: sorted, ranking: ranking)?.displayId,
            1
        )

        let undocked = Monitor.sortedByPosition([builtIn])
        XCTAssertEqual(MonitorDescription.main.resolveMonitor(sortedMonitors: undocked, ranking: ranking)?.displayId, 1)
        XCTAssertNil(MonitorDescription.secondary.resolveMonitor(sortedMonitors: undocked, ranking: ranking))
        XCTAssertNil(MonitorDescription.tertiary.resolveMonitor(sortedMonitors: undocked, ranking: ranking))
    }

    func testTertiaryWithoutRankingIsTheThirdDisplayInDefaultOrder() {
        let sorted = Monitor.sortedByPosition([builtIn, dell, lg])

        XCTAssertEqual(
            MonitorDescription.tertiary.resolveMonitor(sortedMonitors: sorted)?.id,
            MonitorRanking.defaultOrder(sorted)[2].id
        )
        let twoDisplays = Monitor.sortedByPosition([builtIn, dell])
        XCTAssertNil(MonitorDescription.tertiary.resolveMonitor(sortedMonitors: twoDisplays))
    }

    func testTertiaryWorkspaceAssignmentRoundTripsThroughTOML() throws {
        var export = SettingsExport.defaults()
        export.workspaceConfigurations[0].monitorAssignment = .tertiary

        let data = try SettingsTOMLCodec.encode(export)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("type = \"tertiary\""))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).workspaceConfigurations[0].monitorAssignment, .tertiary)
        XCTAssertEqual(MonitorAssignment.tertiary.toMonitorDescription(), .tertiary)
        XCTAssertEqual(MonitorAssignment.tertiary.displayName, "Tertiary")
    }

    func testSecondaryFallsBackToUnrankedMonitorWhenOnlyOneRankedDisplayIsConnected() {
        let sorted = Monitor.sortedByPosition([builtIn, dell, lg])
        let ranking = [OutputId(from: lg)]

        XCTAssertEqual(MonitorDescription.main.resolveMonitor(sortedMonitors: sorted, ranking: ranking)?.displayId, 3)
        XCTAssertEqual(
            MonitorDescription.secondary.resolveMonitor(sortedMonitors: sorted, ranking: ranking)?.id,
            MonitorRanking.defaultOrder(sorted).first(where: { $0.displayId != 3 })?.id
        )
    }

    func testNormalizedTrimsDropsBlanksAndDeduplicates() {
        let twin = Self.makeMonitor(id: 4, x: 7440, name: "DELL U3423WE", uuid: "44444444-4444-4444-4444-444444444444")
        let ranking = [
            OutputId(displayUUID: nil, displayId: nil, name: "  LG HDR 4K "),
            OutputId(displayUUID: nil, displayId: nil, name: "   "),
            OutputId(displayUUID: nil, displayId: nil, name: "lg hdr 4k"),
            OutputId(from: dell),
            OutputId(from: twin),
            OutputId(from: dell)
        ]

        let normalized = MonitorRanking.normalized(ranking)

        XCTAssertEqual(normalized.map(\.name), ["LG HDR 4K", "DELL U3423WE", "DELL U3423WE"])
        XCTAssertEqual(normalized.map(\.displayUUID), [nil, dell.displayUUID, twin.displayUUID])
    }

    func testAddableListsUnrankedConnectedMonitorsInArrangementOrder() {
        let ranking = [OutputId(from: dell)]
        let addable = MonitorRanking.addable(connected: [lg, builtIn, dell], ranking: ranking)

        XCTAssertEqual(addable.map(\.name), ["Built-in Retina Display", "LG HDR 4K"])
        XCTAssertEqual(addable.map(\.displayUUID), [builtIn.displayUUID, lg.displayUUID])
    }

    func testNormalizedKeepsDistinctUUIDLessDisplaysWithTheSameName() {
        let first = Self.makeMonitor(id: 4, x: 7440, name: "Identical Panel", uuid: nil)
        let second = Self.makeMonitor(id: 5, x: 8880, name: "Identical Panel", uuid: nil)
        let ranking = [OutputId(from: second), OutputId(from: first)]
        let normalized = MonitorRanking.normalized(ranking)

        XCTAssertEqual(normalized, ranking)
        XCTAssertEqual(
            MonitorRanking.roleOrder(ranking: normalized, sortedMonitors: [first, second]).map(\.displayId),
            [5, 4]
        )
    }

    func testNormalizedKeepsMixedIdentitiesWhenNamesAreAmbiguous() {
        let twin = Self.makeMonitor(id: 4, x: 7440, name: dell.name, uuid: nil)
        let ranking = [OutputId(name: dell.name), OutputId(from: twin), OutputId(from: dell)]
        let normalized = MonitorRanking.normalized(ranking)
        let reversed = Array(ranking.reversed())

        XCTAssertEqual(normalized, ranking)
        XCTAssertEqual(MonitorRanking.normalized(reversed), reversed)
        XCTAssertEqual(
            MonitorRanking.roleOrder(ranking: normalized, sortedMonitors: [dell, twin]).map(\.displayId),
            [4, 2]
        )
        XCTAssertEqual(MonitorRanking.effectiveRanks(ranking: normalized, monitors: [dell, twin]), [nil, 0, 1])
    }

    func testNormalizedDropsDuplicatesWithinEachIdentityCategory() {
        let stable = OutputId(from: dell)
        let runtime = OutputId(displayId: 4, name: dell.name)
        let nameOnly = OutputId(name: dell.name)
        let ranking = [
            stable,
            OutputId(displayUUID: dell.displayUUID, displayId: 9, name: "Renamed Panel"),
            runtime,
            OutputId(displayId: 4, name: dell.name.lowercased()),
            nameOnly,
            OutputId(name: dell.name.lowercased())
        ]

        XCTAssertEqual(MonitorRanking.normalized(ranking), [stable, runtime, nameOnly])
    }

    func testRankingKeepsBothDisplaysAfterAmbiguousUUIDsAreDiscarded() {
        let twin = Self.makeMonitor(id: 4, x: 7440, name: dell.name, uuid: dell.displayUUID)
        let monitors = Monitor.discardingAmbiguousDisplayUUIDs(in: [dell, twin])
        let ranking = MonitorRanking.normalized(monitors.reversed().map(OutputId.init(from:)))

        XCTAssertEqual(ranking.map(\.displayUUID), [nil, nil])
        XCTAssertEqual(ranking.map(\.displayId), [4, 2])
        XCTAssertEqual(
            MonitorRanking.roleOrder(ranking: ranking, sortedMonitors: monitors).map(\.displayId),
            [4, 2]
        )
        XCTAssertTrue(MonitorRanking.addable(connected: monitors, ranking: ranking).isEmpty)
    }

    func testRoleNames() {
        XCTAssertEqual(MonitorRanking.roleName(forRank: 0), "Main")
        XCTAssertEqual(MonitorRanking.roleName(forRank: 1), "Secondary")
        XCTAssertEqual(MonitorRanking.roleName(forRank: 2), "Tertiary")
        XCTAssertEqual(MonitorRanking.roleName(forRank: 3), "Rank 4")
    }

    func testMovingAndRemoving() {
        let names = ["A", "B", "C"]

        XCTAssertEqual(MonitorRanking.moving(names, from: 1, by: -1), ["B", "A", "C"])
        XCTAssertEqual(MonitorRanking.moving(names, from: 1, by: 1), ["A", "C", "B"])
        XCTAssertEqual(MonitorRanking.moving(names, from: 0, by: -1), names)
        XCTAssertEqual(MonitorRanking.moving(names, from: 2, by: 1), names)
        XCTAssertEqual(MonitorRanking.moving(names, from: 5, by: -1), names)
        XCTAssertEqual(MonitorRanking.removing(names, at: 1), ["A", "C"])
        XCTAssertEqual(MonitorRanking.removing(names, at: 3), names)
    }

    private static func makeMonitor(id: CGDirectDisplayID, x: CGFloat, name: String, uuid: String?) -> Monitor {
        let frame = CGRect(x: x, y: 0, width: 1440, height: 900)
        return Monitor(
            id: Monitor.ID(displayId: id),
            displayId: id,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name,
            displayUUID: uuid
        )
    }
}
