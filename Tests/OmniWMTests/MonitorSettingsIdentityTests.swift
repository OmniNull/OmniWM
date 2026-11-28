// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class MonitorSettingsIdentityTests: XCTestCase {
    private let displayUUIDA = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let displayUUIDB = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"

    @MainActor
    func testStableUUIDsKeepIdenticalNamesDistinctAfterDisplayIdsSwap() {
        let first = makeMonitor(displayId: 3, name: "Identical Panel", displayUUID: displayUUIDA)
        let second = makeMonitor(displayId: 2, name: "Identical Panel", displayUUID: displayUUIDB)
        var export = SettingsExport.defaults()
        export.monitorNiriSettings = [
            MonitorNiriSettings(
                monitorName: first.name,
                monitorDisplayUUID: displayUUIDA,
                monitorDisplayId: 2,
                visibleContainerCount: 1
            ),
            MonitorNiriSettings(
                monitorName: second.name,
                monitorDisplayUUID: displayUUIDB,
                monitorDisplayId: 3,
                visibleContainerCount: 4
            )
        ]
        let settings = makeSettingsStore()

        settings.applyExport(export)

        XCTAssertEqual(settings.niri.settings(for: first)?.visibleContainerCount, 1)
        XCTAssertEqual(settings.niri.settings(for: second)?.visibleContainerCount, 4)
        XCTAssertEqual(settings.niri.monitorOverrides, export.monitorNiriSettings)
    }

    @MainActor
    func testLegacyRowsRemainUnchangedAndUnbound() {
        let monitor = makeMonitor(displayId: 2, name: "Display", displayUUID: displayUUIDA)
        var export = SettingsExport.defaults()
        export.monitorNiriSettings = [
            MonitorNiriSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                visibleContainerCount: 1
            )
        ]
        let settings = makeSettingsStore()

        settings.applyExport(export)

        XCTAssertNil(settings.niri.settings(for: monitor))
        XCTAssertEqual(settings.niri.monitorOverrides, export.monitorNiriSettings)
    }

    @MainActor
    func testTopologyChangesDoNotPromoteOrPersistLegacyRows() throws {
        let primary = makeMonitor(displayId: 2, name: "Primary", displayUUID: displayUUIDA)
        let secondary = makeMonitor(displayId: 3, name: "Secondary", displayUUID: displayUUIDB)
        var export = SettingsExport.defaults()
        export.monitorNiriSettings = [
            MonitorNiriSettings(
                monitorName: secondary.name,
                monitorDisplayId: primary.displayId,
                visibleContainerCount: 2
            )
        ]
        let root = makeTemporaryRoot()
        let persistence = SettingsFilePersistence(
            directory: root.appendingPathComponent("config", isDirectory: true),
            startWatching: false,
            deferSaves: false
        )
        try persistence.saveImmediately(export)
        let settings = SettingsStore(
            persistence: persistence,
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: true
        )
        settings.applyExport(export)
        let before = try Data(contentsOf: settings.settingsFileURL)
        let controller = WMController(settings: settings)

        controller.serviceLifecycleManager.monitorConfiguration.applyMonitorConfigurationChanged(
            currentMonitors: [primary, secondary],
            performPostUpdateActions: false
        )

        let after = try Data(contentsOf: settings.settingsFileURL)
        XCTAssertEqual(after, before)
        XCTAssertEqual(settings.niri.monitorOverrides, export.monitorNiriSettings)
        XCTAssertNil(settings.niri.settings(for: primary))
        XCTAssertNil(settings.niri.settings(for: secondary))
    }

    @MainActor
    func testServiceStartRefreshesStaleBootMonitorSnapshotBeforeServicesBecomeActive() {
        let stale = makeMonitor(displayId: 2, name: "Stale", displayUUID: displayUUIDA)
        let current = makeMonitor(displayId: 3, name: "Current", displayUUID: displayUUIDB)
        let controller = WMController(settings: makeSettingsStore())
        controller.workspaceManager.applyMonitorConfigurationChange([stale])

        XCTAssertEqual(controller.workspaceManager.monitors, [stale])
        XCTAssertFalse(controller.hasStartedServices)

        controller.serviceLifecycleManager.monitorConfiguration.refreshForServiceStart(
            currentMonitors: [current]
        )

        XCTAssertEqual(controller.workspaceManager.monitors, [current])
        XCTAssertFalse(controller.hasStartedServices)
    }

    @MainActor
    func testServiceStartKeepsStaleSnapshotWhenCurrentConfigurationIsTransient() {
        let stale = makeMonitor(displayId: 2, name: "Stale", displayUUID: displayUUIDA)
        let transient = Monitor(
            id: .init(displayId: 3),
            displayId: 3,
            frame: CGRect(x: 0, y: 0, width: 1, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1, height: 900),
            hasNotch: false,
            name: "Transient",
            displayUUID: displayUUIDB
        )
        let controller = WMController(settings: makeSettingsStore())
        controller.workspaceManager.applyMonitorConfigurationChange([stale])

        controller.serviceLifecycleManager.monitorConfiguration.refreshForServiceStart(
            currentMonitors: [transient]
        )

        XCTAssertEqual(controller.workspaceManager.monitors, [stale])
        XCTAssertFalse(controller.hasStartedServices)
    }

    @MainActor
    func testServiceStartDoesNotCommitAnUnchangedMonitorSnapshot() {
        let current = makeMonitor(displayId: 2, name: "Current", displayUUID: displayUUIDA)
        let controller = WMController(settings: makeSettingsStore())
        controller.workspaceManager.applyMonitorConfigurationChange([current])
        let worldSeq = controller.workspaceManager.worldSeq

        controller.serviceLifecycleManager.monitorConfiguration.refreshForServiceStart(
            currentMonitors: [current]
        )

        XCTAssertEqual(controller.workspaceManager.worldSeq, worldSeq)
        XCTAssertFalse(controller.hasStartedServices)
    }

    func testDuplicateStableClaimsFailClosedAndExplicitEditCollapsesThem() {
        let monitor = makeMonitor(displayId: 2, name: "Display", displayUUID: displayUUIDA)
        var overrides = [
            MonitorGapSettings(
                monitorName: monitor.name,
                monitorDisplayUUID: displayUUIDA,
                monitorDisplayId: 7,
                innerGap: 4
            ),
            MonitorGapSettings(
                monitorName: monitor.name,
                monitorDisplayUUID: displayUUIDA,
                monitorDisplayId: 8,
                innerGap: 12
            )
        ]

        XCTAssertNil(MonitorSettingsStore.get(for: monitor, in: overrides))

        MonitorSettingsStore.update(
            MonitorGapSettings(
                monitorName: monitor.name,
                monitorDisplayUUID: displayUUIDA,
                monitorDisplayId: monitor.displayId,
                innerGap: 24
            ),
            for: monitor,
            in: &overrides
        )

        XCTAssertEqual(overrides.count, 1)
        XCTAssertEqual(MonitorSettingsStore.get(for: monitor, in: overrides)?.innerGap, 24)
    }

    func testDifferentUUIDNeverFallsThroughReusedDisplayIdForGetUpdateOrRemove() {
        let monitor = makeMonitor(displayId: 2, name: "Same Name", displayUUID: displayUUIDB)
        let original = MonitorGapSettings(
            monitorName: monitor.name,
            monitorDisplayUUID: displayUUIDA,
            monitorDisplayId: monitor.displayId,
            innerGap: 4
        )
        let replacement = MonitorGapSettings(
            monitorName: monitor.name,
            monitorDisplayUUID: displayUUIDB,
            monitorDisplayId: monitor.displayId,
            innerGap: 24
        )
        var overrides = [original]

        XCTAssertNil(MonitorSettingsStore.get(for: monitor, in: overrides))

        MonitorSettingsStore.update(replacement, for: monitor, in: &overrides)
        XCTAssertEqual(overrides.count, 2)
        XCTAssertEqual(overrides.first(where: { $0.monitorDisplayUUID == displayUUIDA })?.innerGap, 4)
        XCTAssertEqual(overrides.first(where: { $0.monitorDisplayUUID == displayUUIDB })?.innerGap, 24)

        MonitorSettingsStore.remove(for: monitor, from: &overrides)
        XCTAssertEqual(overrides, [original])

        overrides.append(replacement)
        MonitorSettingsStore.remove(for: monitor, from: &overrides)
        XCTAssertEqual(overrides, [original])
    }

    func testMalformedUUIDIsRejectedAndCannotBindAStableMonitor() {
        let monitor = makeMonitor(displayId: 2, name: "Display", displayUUID: displayUUIDA)
        let malformed = MonitorGapSettings(
            monitorName: monitor.name,
            monitorDisplayUUID: "not-a-uuid",
            monitorDisplayId: monitor.displayId,
            innerGap: 4
        )

        XCTAssertNil(malformed.monitorDisplayUUID)
        XCTAssertNil(MonitorSettingsStore.get(for: monitor, in: [malformed]))
        XCTAssertEqual(
            DisplayUUID.canonical("  aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa  "),
            displayUUIDA
        )
    }

    func testMalformedPersistedUUIDsFailInsteadOfDowngradingIdentity() throws {
        var export = SettingsExport.defaults()
        export.monitorGapSettings = [
            MonitorGapSettings(
                monitorName: "Display",
                monitorDisplayUUID: displayUUIDA,
                monitorDisplayId: 2,
                innerGap: 4
            )
        ]
        let validLuau = String(decoding: try SettingsLuauDocument.initialSource(export), as: UTF8.self)
        let malformedLuau = validLuau.replacingOccurrences(of: displayUUIDA, with: "not-a-uuid")
        let malformedOutput = Data(
            #"{"displayUUID":"not-a-uuid","displayId":2,"name":"Display"}"#.utf8
        )

        XCTAssertThrowsError(try SettingsLuauFixture.decode(Data(malformedLuau.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(OutputId.self, from: malformedOutput))
    }

    func testLiveUUIDCollisionFallsBackToRuntimeDisplayIdentity() {
        let raw = [
            makeMonitor(displayId: 2, name: "Identical Panel", displayUUID: displayUUIDA),
            makeMonitor(displayId: 3, name: "Identical Panel", displayUUID: displayUUIDA)
        ]
        let monitors = Monitor.discardingAmbiguousDisplayUUIDs(in: raw)
        let stableOverride = MonitorGapSettings(
            monitorName: "Identical Panel",
            monitorDisplayUUID: displayUUIDA,
            monitorDisplayId: 2,
            innerGap: 4
        )
        let runtimeOverrides = monitors.enumerated().map { index, monitor in
            MonitorGapSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                innerGap: Double(index + 1)
            )
        }

        XCTAssertTrue(monitors.allSatisfy { $0.displayUUID == nil })
        XCTAssertTrue(monitors.allSatisfy {
            MonitorSettingsStore.get(for: $0, in: [stableOverride]) == nil
        })
        XCTAssertEqual(MonitorSettingsStore.get(for: monitors[0], in: runtimeOverrides)?.innerGap, 1)
        XCTAssertEqual(MonitorSettingsStore.get(for: monitors[1], in: runtimeOverrides)?.innerGap, 2)
    }

    func testStableIdentityReturnCollapsesAndRemovesSessionFallbackRows() {
        let stable = makeMonitor(displayId: 2, name: "Display", displayUUID: displayUUIDA)
        let sessionFallback = makeMonitor(displayId: 2, name: "Display", displayUUID: nil)
        var overrides = [
            MonitorGapSettings(
                monitorName: stable.name,
                monitorDisplayUUID: stable.displayUUID,
                monitorDisplayId: stable.displayId,
                innerGap: 4
            )
        ]

        MonitorSettingsStore.update(
            MonitorGapSettings(
                monitorName: sessionFallback.name,
                monitorDisplayId: sessionFallback.displayId,
                innerGap: 8
            ),
            for: sessionFallback,
            in: &overrides
        )
        XCTAssertEqual(overrides.count, 2)

        MonitorSettingsStore.update(
            MonitorGapSettings(
                monitorName: stable.name,
                monitorDisplayUUID: stable.displayUUID,
                monitorDisplayId: stable.displayId,
                innerGap: 12
            ),
            for: stable,
            in: &overrides
        )
        XCTAssertEqual(overrides.count, 1)
        XCTAssertEqual(overrides[0].monitorDisplayUUID, displayUUIDA)
        XCTAssertEqual(overrides[0].innerGap, 12)

        MonitorSettingsStore.update(
            MonitorGapSettings(
                monitorName: sessionFallback.name,
                monitorDisplayId: sessionFallback.displayId,
                innerGap: 16
            ),
            for: sessionFallback,
            in: &overrides
        )
        XCTAssertEqual(overrides.count, 2)

        MonitorSettingsStore.remove(for: stable, from: &overrides)
        XCTAssertTrue(overrides.isEmpty)
    }

    @MainActor
    func testDisplayObserverNoticesIdentityChangesWithoutGeometryChanges() {
        let previous = makeMonitor(displayId: 2, name: "Display", displayUUID: displayUUIDA)
        let renamed = makeMonitor(displayId: 2, name: "Renamed", displayUUID: displayUUIDA)
        let replacement = makeMonitor(displayId: 2, name: "Display", displayUUID: displayUUIDB)

        XCTAssertFalse(
            DisplayConfigurationObserver.requiresReconfiguration(
                previous: previous,
                current: previous
            )
        )
        XCTAssertTrue(
            DisplayConfigurationObserver.requiresReconfiguration(
                previous: previous,
                current: renamed
            )
        )
        XCTAssertTrue(
            DisplayConfigurationObserver.requiresReconfiguration(
                previous: previous,
                current: replacement
            )
        )
    }

    func testOverrideIdentityPersistence() throws {
        let cases: [(String?, CGDirectDisplayID?, String, String)] = [
            (displayUUIDA, nil, "monitorDisplayUUID =", "monitorDisplayId ="),
            (nil, 7, "monitorDisplayId =", "monitorDisplayUUID =")
        ]
        for (uuid, expectedRuntimeId, persistedKey, absentKey) in cases {
            var export = SettingsExport.defaults()
            export.routing.arrangements = [MonitorArrangement(monitors: [
                MonitorRoutingSettings(
                    monitorName: "Display",
                    monitorDisplayUUID: uuid,
                    monitorDisplayId: 7,
                    gridColumn: 0,
                    gridRow: 0
                )
            ])]
            export.monitorBarSettings = [
                MonitorBarSettings(
                    monitorName: "Display",
                    monitorDisplayUUID: uuid,
                    monitorDisplayId: 7,
                    enabled: true
                )
            ]
            export.monitorOrientationSettings = [
                MonitorOrientationSettings(
                    monitorName: "Display",
                    monitorDisplayUUID: uuid,
                    monitorDisplayId: 7,
                    orientation: .horizontal
                )
            ]
            export.monitorNiriSettings = [
                MonitorNiriSettings(
                    monitorName: "Display",
                    monitorDisplayUUID: uuid,
                    monitorDisplayId: 7,
                    visibleContainerCount: 2
                )
            ]
            export.monitorDwindleSettings = [
                MonitorDwindleSettings(
                    monitorName: "Display",
                    monitorDisplayUUID: uuid,
                    monitorDisplayId: 7,
                    smartSplit: true
                )
            ]
            export.monitorGapSettings = [
                MonitorGapSettings(
                    monitorName: "Display",
                    monitorDisplayUUID: uuid,
                    monitorDisplayId: 7,
                    innerGap: 6
                )
            ]

            let data = try SettingsLuauDocument.initialSource(export)
            let source = String(decoding: data, as: UTF8.self)
            let decoded = try SettingsLuauFixture.decode(data)

            XCTAssertEqual(source.components(separatedBy: persistedKey).count - 1, 6)
            XCTAssertFalse(source.contains(absentKey))
            XCTAssertEqual(decoded.routing.arrangements.first?.monitors.first?.monitorDisplayUUID, uuid)
            XCTAssertEqual(decoded.monitorBarSettings.first?.monitorDisplayUUID, uuid)
            XCTAssertEqual(decoded.monitorOrientationSettings.first?.monitorDisplayUUID, uuid)
            XCTAssertEqual(decoded.monitorNiriSettings.first?.monitorDisplayUUID, uuid)
            XCTAssertEqual(decoded.monitorDwindleSettings.first?.monitorDisplayUUID, uuid)
            XCTAssertEqual(decoded.monitorGapSettings.first?.monitorDisplayUUID, uuid)
            XCTAssertEqual(decoded.routing.arrangements.first?.monitors.first?.monitorDisplayId, expectedRuntimeId)
            XCTAssertEqual(decoded.monitorBarSettings.first?.monitorDisplayId, expectedRuntimeId)
            XCTAssertEqual(decoded.monitorOrientationSettings.first?.monitorDisplayId, expectedRuntimeId)
            XCTAssertEqual(decoded.monitorNiriSettings.first?.monitorDisplayId, expectedRuntimeId)
            XCTAssertEqual(decoded.monitorDwindleSettings.first?.monitorDisplayId, expectedRuntimeId)
            XCTAssertEqual(decoded.monitorGapSettings.first?.monitorDisplayId, expectedRuntimeId)
        }
    }

    @MainActor
    func testAllExplicitUpdateAPIsStampTheSelectedMonitorIdentity() throws {
        let monitor = makeMonitor(displayId: 42, name: "Selected", displayUUID: displayUUIDA)
        let settings = makeSettingsStore()

        settings.workspaceBar.update(
            MonitorBarSettings(
                monitorName: "Wrong",
                monitorDisplayUUID: displayUUIDB,
                monitorDisplayId: 7,
                enabled: false
            ),
            for: monitor
        )
        settings.monitors.updateOrientationSettings(
            MonitorOrientationSettings(
                monitorName: "Wrong",
                monitorDisplayUUID: displayUUIDB,
                monitorDisplayId: 7,
                orientation: .vertical
            ),
            for: monitor
        )
        settings.niri.update(
            MonitorNiriSettings(
                monitorName: "Wrong",
                monitorDisplayUUID: displayUUIDB,
                monitorDisplayId: 7,
                visibleContainerCount: 1
            ),
            for: monitor
        )
        settings.dwindle.update(
            MonitorDwindleSettings(
                monitorName: "Wrong",
                monitorDisplayUUID: displayUUIDB,
                monitorDisplayId: 7,
                smartSplit: true
            ),
            for: monitor
        )
        settings.gaps.update(
            MonitorGapSettings(
                monitorName: "Wrong",
                monitorDisplayUUID: displayUUIDB,
                monitorDisplayId: 7,
                innerGap: 0,
                fullscreenUsesOuterGaps: false
            ),
            for: monitor
        )

        assertIdentity(try XCTUnwrap(settings.workspaceBar.monitorOverrides.first), monitor: monitor)
        assertIdentity(try XCTUnwrap(settings.monitors.orientationOverrides.first), monitor: monitor)
        assertIdentity(try XCTUnwrap(settings.niri.monitorOverrides.first), monitor: monitor)
        assertIdentity(try XCTUnwrap(settings.dwindle.monitorOverrides.first), monitor: monitor)
        assertIdentity(try XCTUnwrap(settings.gaps.monitorOverrides.first), monitor: monitor)
        XCTAssertEqual(settings.gaps.monitorOverrides.first?.fullscreenUsesOuterGaps, false)
    }

    func testPreservingEncodeDoesNotResurrectLegacyRuntimeDisplayId() throws {
        let recordId = UUID()
        var legacy = SettingsExport.defaults()
        legacy.monitorNiriSettings = [
            MonitorNiriSettings(
                id: recordId,
                monitorName: "Display",
                monitorDisplayId: 7,
                visibleContainerCount: 2
            )
        ]
        var stable = legacy
        stable.monitorNiriSettings = [
            MonitorNiriSettings(
                id: recordId,
                monitorName: "Display",
                monitorDisplayUUID: displayUUIDA,
                monitorDisplayId: 7,
                visibleContainerCount: 2
            )
        ]

        let data = try SettingsLuauFixture.editing(SettingsLuauDocument.initialSource(legacy), to: stable)
        let source = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(source.contains("monitorDisplayUUID = \"\(displayUUIDA)\""))
        XCTAssertFalse(source.contains("monitorDisplayId ="))
    }

    func testCustomRoutingSeedsOnlyWhenNoArrangementCoversConnectedSet() {
        let first = makeMonitor(displayId: 2, name: "First", displayUUID: displayUUIDA)
        let second = makeMonitor(displayId: 3, name: "Second", displayUUID: displayUUIDB)
        let arrangement = MonitorArrangement(monitors: MonitorRouting.seedLayout(from: [first, second]))

        XCTAssertFalse(MonitorSettingsTabModel.shouldSeedRouting(arrangements: [], monitors: []))
        XCTAssertTrue(MonitorSettingsTabModel.shouldSeedRouting(arrangements: [], monitors: [first, second]))
        XCTAssertFalse(MonitorSettingsTabModel.shouldSeedRouting(
            arrangements: [arrangement],
            monitors: [first, second]
        ))
        XCTAssertFalse(MonitorSettingsTabModel.shouldSeedRouting(arrangements: [arrangement], monitors: [first]))
        XCTAssertTrue(MonitorSettingsTabModel.shouldSeedRouting(
            arrangements: [MonitorArrangement(monitors: MonitorRouting.seedLayout(from: [first]))],
            monitors: [second]
        ))
    }

    func testRoutingEditorUsesEphemeralMacOSLayoutForLegacyConfiguration() throws {
        let first = makeMonitor(displayId: 2, name: "First", displayUUID: displayUUIDA)
        let second = makeMonitor(displayId: 3, name: "Second", displayUUID: displayUUIDB)
        let monitors = [first, second]
        let legacy = [
            MonitorRoutingSettings(
                monitorName: first.name,
                monitorDisplayId: first.displayId,
                gridColumn: 7,
                gridRow: 4
            )
        ]
        let original = legacy

        let editorLayout = MonitorSettingsTabModel.routingEditorLayout(
            arrangements: [MonitorArrangement(monitors: legacy)],
            monitors: monitors
        )

        XCTAssertTrue(editorLayout.usesMacOSFallback)
        XCTAssertEqual(editorLayout.source, .macOS)
        XCTAssertEqual(editorLayout.settings.count, monitors.count)
        XCTAssertEqual(
            try XCTUnwrap(MonitorSettingsStore.get(for: first, in: editorLayout.settings)).gridColumn,
            0
        )
        XCTAssertEqual(
            try XCTUnwrap(MonitorSettingsStore.get(for: second, in: editorLayout.settings)).gridColumn,
            1
        )
        XCTAssertNil(MonitorSettingsStore.get(for: first, in: legacy))
        XCTAssertEqual(legacy, original)
    }

    func testRoutingEditorPreservesCompleteCustomLayoutAndIgnoresDisconnectedRows() throws {
        let first = makeMonitor(displayId: 2, name: "First", displayUUID: displayUUIDA)
        let second = makeMonitor(displayId: 3, name: "Second", displayUUID: displayUUIDB)
        let disconnectedUUID = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
        let existing = [
            MonitorRoutingSettings(
                monitorName: first.name,
                monitorDisplayUUID: first.displayUUID,
                gridColumn: 4,
                gridRow: 2
            ),
            MonitorRoutingSettings(
                monitorName: second.name,
                monitorDisplayUUID: second.displayUUID,
                gridColumn: -1,
                gridRow: 2
            ),
            MonitorRoutingSettings(
                monitorName: "Disconnected",
                monitorDisplayUUID: disconnectedUUID,
                gridColumn: 9,
                gridRow: 9
            )
        ]

        let editorLayout = MonitorSettingsTabModel.routingEditorLayout(
            arrangements: [MonitorArrangement(monitors: existing)],
            monitors: [first, second]
        )

        XCTAssertFalse(editorLayout.usesMacOSFallback)
        XCTAssertEqual(editorLayout.source, .inherited)
        XCTAssertEqual(editorLayout.settings.count, 2)
        let firstEntry = try XCTUnwrap(MonitorSettingsStore.get(for: first, in: editorLayout.settings))
        let secondEntry = try XCTUnwrap(MonitorSettingsStore.get(for: second, in: editorLayout.settings))
        XCTAssertEqual(firstEntry.gridColumn, 4)
        XCTAssertEqual(firstEntry.gridRow, 2)
        XCTAssertEqual(secondEntry.gridColumn, -1)
        XCTAssertEqual(secondEntry.gridRow, 2)
        XCTAssertEqual(existing.count, 3)

        let exactRows = MonitorRouting.seedLayout(from: [first, second])
        let exactLayout = MonitorSettingsTabModel.routingEditorLayout(
            arrangements: [MonitorArrangement(monitors: existing), MonitorArrangement(monitors: exactRows)],
            monitors: [first, second]
        )

        XCTAssertEqual(exactLayout.source, .exact)
        XCTAssertEqual(exactLayout.settings, exactRows)
    }

    func testRoutingEditorFallsBackWhenLiveCellsCollide() throws {
        let first = makeMonitor(displayId: 2, name: "First", displayUUID: displayUUIDA)
        let second = makeMonitor(displayId: 3, name: "Second", displayUUID: displayUUIDB)
        let existing = [
            MonitorRoutingSettings(
                monitorName: first.name,
                monitorDisplayUUID: first.displayUUID,
                gridColumn: 0,
                gridRow: 0
            ),
            MonitorRoutingSettings(
                monitorName: second.name,
                monitorDisplayUUID: second.displayUUID,
                gridColumn: 0,
                gridRow: 0
            )
        ]

        let editorLayout = MonitorSettingsTabModel.routingEditorLayout(
            arrangements: [MonitorArrangement(monitors: existing)],
            monitors: [first, second]
        )

        XCTAssertTrue(editorLayout.usesMacOSFallback)
        XCTAssertFalse(MonitorSettingsTabModel.shouldSeedRouting(
            arrangements: [MonitorArrangement(monitors: existing)],
            monitors: [first, second]
        ))
        let firstEntry = try XCTUnwrap(MonitorSettingsStore.get(for: first, in: editorLayout.settings))
        let secondEntry = try XCTUnwrap(MonitorSettingsStore.get(for: second, in: editorLayout.settings))
        XCTAssertNotEqual(firstEntry.gridColumn, secondEntry.gridColumn)
    }

    func testRoutingEditorSubsetEditPersistsStableRowsAndPreservesLargerArrangement() throws {
        let first = makeMonitor(displayId: 2, name: "First", displayUUID: displayUUIDA)
        let second = makeMonitor(displayId: 3, name: "Second", displayUUID: displayUUIDB)
        let disconnectedUUID = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
        let disconnected = MonitorRoutingSettings(
            monitorName: "Disconnected",
            monitorDisplayUUID: disconnectedUUID,
            gridColumn: 9,
            gridRow: 9
        )
        let inherited = MonitorArrangement(monitors: MonitorRouting.seedLayout(from: [first, second]) + [disconnected])
        var arrangements = [inherited]

        let updated = MonitorSettingsTabModel.routingSettingsAfterEdit(
            monitors: [first, second],
            cells: [
                first.id: (column: 0, row: 0),
                second.id: (column: 2, row: 0)
            ]
        )

        let firstEntry = try XCTUnwrap(MonitorSettingsStore.get(for: first, in: updated))
        let secondEntry = try XCTUnwrap(MonitorSettingsStore.get(for: second, in: updated))
        XCTAssertEqual(firstEntry.monitorDisplayUUID, displayUUIDA)
        XCTAssertEqual(secondEntry.monitorDisplayUUID, displayUUIDB)
        XCTAssertEqual(firstEntry.gridColumn, 0)
        XCTAssertEqual(firstEntry.gridRow, 0)
        XCTAssertEqual(secondEntry.gridColumn, 2)
        XCTAssertEqual(secondEntry.gridRow, 0)
        assertIdentity(firstEntry, monitor: first)
        assertIdentity(secondEntry, monitor: second)
        XCTAssertEqual(updated.count, 2)
        XCTAssertNotNil(MonitorRouting.completeLayout(updated, for: [first, second]))

        MonitorRouting.store(updated, for: [first, second], in: &arrangements)

        XCTAssertEqual(arrangements.count, 2)
        XCTAssertEqual(arrangements[0], inherited)
        XCTAssertNotEqual(arrangements[1].id, inherited.id)
        XCTAssertEqual(arrangements[1].monitors, updated)
        XCTAssertEqual(
            MonitorSettingsTabModel.routingEditorLayout(arrangements: arrangements, monitors: [first, second]).source,
            .exact
        )

        let exactID = arrangements[1].id
        let reset = MonitorRouting.seedLayout(from: [first, second])
        MonitorRouting.store(reset, for: [first, second], in: &arrangements)

        XCTAssertEqual(arrangements.count, 2)
        XCTAssertEqual(arrangements[0], inherited)
        XCTAssertEqual(arrangements[1].id, exactID)
        XCTAssertEqual(arrangements[1].monitors, reset)
    }

    func testOutputIdFollowsUUIDAcrossRuntimeIdentityChanges() throws {
        let original = makeMonitor(displayId: 2, name: "Old Name", displayUUID: displayUUIDA)
        let current = makeMonitor(displayId: 9, name: "New Name", displayUUID: displayUUIDA)
        let recycled = makeMonitor(displayId: 2, name: "Old Name", displayUUID: displayUUIDB)
        let output = OutputId(from: original)

        XCTAssertEqual(output.resolveMonitor(in: [recycled, current]), current)
        XCTAssertNil(output.resolveMonitor(in: [recycled]))
        XCTAssertEqual(output, OutputId(from: current))

        let data = try JSONEncoder().encode(output)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(encoded.contains("\"displayUUID\""))
        XCTAssertFalse(encoded.contains("\"displayId\""))
    }

    func testOutputIdFailsClosedForDuplicateUUIDAndLegacyUsesUUIDLessRuntimeIdentity() {
        let duplicateA = makeMonitor(displayId: 2, name: "First", displayUUID: displayUUIDA)
        let duplicateB = makeMonitor(displayId: 3, name: "Second", displayUUID: displayUUIDA)
        let stable = OutputId(from: duplicateA)
        let runtime = OutputId(displayId: 3, name: "Second")
        let uuidLess = makeMonitor(displayId: 3, name: "Second", displayUUID: nil)

        XCTAssertNil(stable.resolveMonitor(in: [duplicateA, duplicateB]))
        XCTAssertNil(runtime.resolveMonitor(in: [duplicateB]))
        XCTAssertEqual(runtime.resolveMonitor(in: [uuidLess]), uuidLess)
    }

    func testUUIDLessOutputHashingUsesTheSameIdentityAsEquality() {
        let first = OutputId(displayId: 3, name: "ß")
        let second = OutputId(displayId: 3, name: "SS")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 2)
    }

    @MainActor
    func testWorkspaceOutputLoadDoesNotRebindLegacyIdentity() throws {
        let configurationId = UUID()
        let legacyOutput = OutputId(displayId: 7, name: "Display")
        let monitor = makeMonitor(displayId: 7, name: "Display", displayUUID: displayUUIDA)
        var export = SettingsExport.defaults()
        export.workspaceConfigurations = [
            WorkspaceConfiguration(
                id: configurationId,
                name: "1",
                monitorAssignment: .specificDisplay(legacyOutput)
            )
        ]
        let settings = makeSettingsStore()

        settings.applyExport(export)

        XCTAssertEqual(settings.workspaces.configurations, export.workspaceConfigurations)
        guard case let .specificDisplay(loadedOutput) = settings.workspaces.configurations[0].monitorAssignment else {
            return XCTFail("Expected specific display assignment")
        }
        XCTAssertNil(loadedOutput.displayUUID)
        XCTAssertNil(loadedOutput.resolveMonitor(in: [monitor]))
    }

    func testWorkspaceOutputUUIDPersistenceDoesNotResurrectLegacyDisplayId() throws {
        let configurationId = UUID()
        var legacy = SettingsExport.defaults()
        legacy.workspaceConfigurations = [
            WorkspaceConfiguration(
                id: configurationId,
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(displayId: 7, name: "Display"))
            )
        ]
        var stable = legacy
        stable.workspaceConfigurations = [
            WorkspaceConfiguration(
                id: configurationId,
                name: "1",
                monitorAssignment: .specificDisplay(
                    OutputId(
                        displayUUID: displayUUIDA,
                        displayId: 7,
                        name: "Display"
                    )
                )
            )
        ]

        let data = try SettingsLuauFixture.editing(SettingsLuauDocument.initialSource(legacy), to: stable)
        let source = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsLuauFixture.decode(data)

        XCTAssertTrue(source.contains("displayUUID = \"\(displayUUIDA)\""))
        XCTAssertFalse(source.contains("displayId ="))
        guard case let .specificDisplay(output) = decoded.workspaceConfigurations[0].monitorAssignment else {
            return XCTFail("Expected specific display assignment")
        }
        XCTAssertEqual(output.displayUUID, displayUUIDA)
        XCTAssertNil(output.displayId)
    }

    private func makeMonitor(
        displayId: CGDirectDisplayID,
        name: String,
        displayUUID: String?
    ) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: CGFloat(displayId) * 100, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: CGFloat(displayId) * 100, y: 0, width: 1440, height: 900),
            hasNotch: false,
            name: name,
            displayUUID: displayUUID
        )
    }

    private func assertIdentity<T: MonitorSettingsType>(
        _ setting: T,
        monitor: Monitor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(setting.monitorName, monitor.name, file: file, line: line)
        XCTAssertEqual(setting.monitorDisplayUUID, monitor.displayUUID, file: file, line: line)
        XCTAssertEqual(setting.monitorDisplayId, monitor.displayId, file: file, line: line)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = makeTemporaryRoot()
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }

    private func makeTemporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMMonitorIdentityTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
