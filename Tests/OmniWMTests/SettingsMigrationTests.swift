// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
@testable import OmniWM
import XCTest

final class SettingsMigrationTests: XCTestCase {
    func testVersionZeroFixturesMigrateCustomValuesAndReportExactChanges() throws {
        let cases: [(
            name: String,
            raise: Bool,
            fullscreenGaps: Bool,
            defaultedPaths: Set<String>,
            retired: Set<String>
        )] = [
            (
                "v0.6.2-custom",
                true,
                false,
                [
                    "focus.raiseOnMouseFocus",
                    "gaps.fullscreenUsesOuterGaps",
                    "workspaceBar.hideInNativeFullscreen",
                    "scratchpads.labels",
                    "routing.arrangements"
                ],
                ["consumeOrExpelWindowLeft", "consumeOrExpelWindowRight"]
            ),
            (
                "v0.6.3-custom",
                false,
                true,
                ["workspaceBar.hideInNativeFullscreen", "scratchpads.labels", "routing.arrangements"],
                []
            )
        ]

        for testCase in cases {
            let result = try SettingsTOMLCodec.decodeForLoad(legacyFixtureData(named: testCase.name))
            let migration = try XCTUnwrap(result.migration)
            let migratedData = try XCTUnwrap(result.migratedData)
            let export = result.export

            XCTAssertEqual(migration.fromVersion, 0, testCase.name)
            XCTAssertEqual(migration.toVersion, 5, testCase.name)
            XCTAssertEqual(Set(migration.defaultedPaths), testCase.defaultedPaths, testCase.name)
            XCTAssertEqual(Set(migration.addedHotkeyIDs), expectedAddedHotkeyIDs, testCase.name)
            XCTAssertEqual(
                Set(migration.retiredHotkeys.map(\.id)),
                testCase.retired,
                testCase.name
            )
            XCTAssertEqual(
                Set(migration.retiredHotkeys.flatMap(\.suggestedIDs)),
                testCase.retired.isEmpty ? [] : ["consumeWindowIntoColumn", "expelWindowFromColumn"],
                testCase.name
            )

            XCTAssertTrue(export.focus.followsMouse, testCase.name)
            XCTAssertEqual(export.focus.raiseOnMouseFocus, testCase.raise, testCase.name)
            XCTAssertEqual(export.gaps.size, 27, testCase.name)
            XCTAssertEqual(export.gaps.fullscreenUsesOuterGaps, testCase.fullscreenGaps, testCase.name)
            XCTAssertEqual(export.defaultLayoutType, .dwindle, testCase.name)
            XCTAssertFalse(export.workspaceBar.hideInNativeFullscreen, testCase.name)
            XCTAssertEqual(export.workspaceBar.excludedBundleIDs, ["com.example.Hidden"], testCase.name)
            XCTAssertEqual(export.scratchpads.labels, [:], testCase.name)
            XCTAssertNil(export.niri.defaultContainerPrimarySpan, testCase.name)

            let workspace = try XCTUnwrap(export.workspaceConfigurations.only, testCase.name)
            XCTAssertEqual(workspace.id.uuidString, "11111111-1111-1111-1111-111111111111", testCase.name)
            XCTAssertEqual(workspace.name, "dev", testCase.name)
            XCTAssertEqual(workspace.displayName, "Development", testCase.name)
            XCTAssertEqual(workspace.monitorAssignment, .secondary, testCase.name)
            XCTAssertEqual(workspace.layoutType, .dwindle, testCase.name)

            let rule = try XCTUnwrap(export.appRules.only, testCase.name)
            XCTAssertEqual(rule.id.uuidString, "22222222-2222-2222-2222-222222222222", testCase.name)
            XCTAssertEqual(rule.bundleId, "com.example.Terminal", testCase.name)
            XCTAssertEqual(rule.titleRegex, "^Project", testCase.name)
            XCTAssertEqual(rule.layout, .float, testCase.name)
            XCTAssertEqual(rule.assignToWorkspace, "dev", testCase.name)
            XCTAssertEqual(rule.initialContainerPrimarySpan, 0.65, testCase.name)
            XCTAssertEqual(rule.minWidth, 720, testCase.name)
            XCTAssertEqual(rule.minHeight, 480, testCase.name)

            XCTAssertEqual(hotkey("swapSplit", in: export)?.binding.humanReadableString, "Option+J", testCase.name)
            XCTAssertEqual(
                hotkey("assignFocusedWindowToScratchpad.1", in: export)?.binding.humanReadableString,
                "Option+J",
                testCase.name
            )
            XCTAssertEqual(
                hotkey("toggleScratchpad.1", in: export)?.binding.humanReadableString,
                "Option+K",
                testCase.name
            )
            for id in expectedAddedHotkeyIDs {
                XCTAssertTrue(hotkey(id, in: export)?.binding.isUnassigned == true, "\(testCase.name): \(id)")
            }
            XCTAssertNil(hotkey("assignFocusedWindowToScratchpad", in: export), testCase.name)
            XCTAssertNil(hotkey("toggleScratchpadWindow", in: export), testCase.name)
            XCTAssertNil(hotkey("consumeOrExpelWindowLeft", in: export), testCase.name)
            XCTAssertNil(hotkey("consumeOrExpelWindowRight", in: export), testCase.name)

            XCTAssertEqual(
                migration.mappedHotkeys,
                [
                    SettingsHotkeyMapping(
                        previousID: "assignFocusedWindowToScratchpad",
                        currentID: "assignFocusedWindowToScratchpad.1",
                        keptExplicitCurrentBinding: false
                    ),
                    SettingsHotkeyMapping(
                        previousID: "toggleScratchpadWindow",
                        currentID: "toggleScratchpad.1",
                        keptExplicitCurrentBinding: false
                    )
                ] + expectedVersionFiveMappings,
                testCase.name
            )
            let migratedText = String(decoding: migratedData, as: UTF8.self)
            XCTAssertTrue(migratedText.contains("schemaVersion = 5"), testCase.name)
            let unknownPaths = Set(SettingsTOMLCodec.unknownKeyPaths(in: migratedData))
            XCTAssertTrue(unknownPaths.contains("general.futureSetting"), testCase.name)
            XCTAssertTrue(unknownPaths.contains("futureExtension"), testCase.name)
        }
    }

    func testVersionTwoMigrationMovesRoutingRowsAndTheirExtensionsIntoOneArrangement() throws {
        let data = try versionTwoData(routingRows: """
        [[monitorRoutingOverrides]]
        monitorName = "Laptop"
        monitorDisplayUUID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        gridColumn = 0
        gridRow = 1
        futureRoutingSetting = "keep"

        [[monitorRoutingOverrides]]
        monitorName = "External"
        monitorDisplayUUID = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        gridColumn = 0
        gridRow = 0
        """)
        let result = try SettingsTOMLCodec.decodeForLoad(data)
        let report = try XCTUnwrap(result.migration)
        let migratedData = try XCTUnwrap(result.migratedData)
        let arrangement = try XCTUnwrap(result.export.routing.arrangements.only)

        XCTAssertEqual(report.fromVersion, 2)
        XCTAssertEqual(report.toVersion, 5)
        XCTAssertEqual(report.defaultedPaths, ["routing.arrangements"])
        XCTAssertTrue(report.addedHotkeyIDs.isEmpty)
        XCTAssertTrue(report.mappedHotkeys.isEmpty)
        XCTAssertTrue(report.retiredHotkeys.isEmpty)
        XCTAssertEqual(result.export.routing.mode, .custom)
        XCTAssertEqual(result.export.gaps.size, 27)
        XCTAssertEqual(arrangement.monitors, [
            MonitorRoutingSettings(
                monitorName: "Laptop",
                monitorDisplayUUID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
                gridColumn: 0,
                gridRow: 1
            ),
            MonitorRoutingSettings(
                monitorName: "External",
                monitorDisplayUUID: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
                gridColumn: 0,
                gridRow: 0
            )
        ])
        XCTAssertEqual(
            SettingsTOMLCodec.unknownKeyPaths(in: migratedData),
            ["routing.arrangements[0].monitors[0].futureRoutingSetting"]
        )
        XCTAssertFalse(String(decoding: migratedData, as: UTF8.self).contains("monitorRoutingOverrides"))

        let reloaded = try SettingsTOMLCodec.decodeForLoad(migratedData)
        XCTAssertNil(reloaded.migration)
        XCTAssertNil(reloaded.migratedData)
        XCTAssertEqual(reloaded.export, result.export)
        XCTAssertEqual(reloaded.export.routing.arrangements.only?.id, arrangement.id)
    }

    func testVersionTwoMigrationPreservesRoutingWithDisconnectedRows() throws {
        let data = try versionTwoData(routingRows: """
        [[monitorRoutingOverrides]]
        monitorName = "Laptop"
        monitorDisplayId = 1
        gridColumn = 0
        gridRow = 1

        [[monitorRoutingOverrides]]
        monitorName = "Home"
        monitorDisplayId = 2
        gridColumn = 0
        gridRow = 0

        [[monitorRoutingOverrides]]
        monitorName = "Work"
        monitorDisplayId = 3
        gridColumn = 0
        gridRow = 0
        """)
        let result = try SettingsTOMLCodec.decodeForLoad(data)
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let monitors = [(UInt32(1), "Laptop"), (UInt32(2), "Home")].map { id, name in
            Monitor(
                id: Monitor.ID(displayId: id),
                displayId: id,
                frame: frame,
                visibleFrame: frame,
                hasNotch: false,
                name: name
            )
        }
        let layout = MonitorRouting.layout(for: monitors, in: result.export.routing.arrangements)

        XCTAssertEqual(result.export.routing.arrangements.only?.monitors.count, 3)
        XCTAssertEqual(MonitorRouting.completeLayout(layout, for: monitors)?.count, 2)
        XCTAssertEqual(
            MonitorRouting.gridAdjacent(
                from: monitors[0],
                direction: .up,
                layout: layout,
                monitors: monitors,
                wrapAround: false
            ),
            .monitor(monitors[1])
        )
    }

    func testVersionTwoMigrationKeepsEmptyRoutingEmpty() throws {
        let result = try SettingsTOMLCodec.decodeForLoad(versionTwoData())

        XCTAssertTrue(result.export.routing.arrangements.isEmpty)
        XCTAssertEqual(result.migration?.fromVersion, 2)
        XCTAssertEqual(result.migration?.toVersion, 5)
        XCTAssertEqual(result.migration?.defaultedPaths, ["routing.arrangements"])
        XCTAssertEqual(result.export.routing.mode, .custom)
    }

    func testVersionFourMigrationRenamesResizeHotkeysAndKeepsTheirBindings() throws {
        var text = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
            .replacingOccurrences(of: "schemaVersion = 5", with: "schemaVersion = 4")
        for mapping in expectedVersionFiveMappings {
            text = text.replacingOccurrences(of: "\"\(mapping.currentID)\"", with: "\"\(mapping.previousID)\"")
        }

        let result = try SettingsTOMLCodec.decodeForLoad(Data(text.utf8))
        let migration = try XCTUnwrap(result.migration)

        XCTAssertEqual(migration.fromVersion, 4)
        XCTAssertEqual(migration.toVersion, 5)
        XCTAssertEqual(migration.mappedHotkeys, expectedVersionFiveMappings)
        XCTAssertEqual(result.export.hotkeyBindings, SettingsExport.defaults().hotkeyBindings)
        XCTAssertEqual(
            hotkey("resizeContainerPrimarySpan.shrink", in: result.export)?.binding.humanReadableString,
            "Option+Minus"
        )
    }

    @MainActor
    func testVersionFourMigrationValidatesDiscardedResizeAliases() throws {
        let canonical = try SettingsTOMLCodec.encode(.defaults())
        let original = Data(String(decoding: canonical, as: UTF8.self)
            .replacingOccurrences(of: "schemaVersion = 5", with: "schemaVersion = 4").utf8)
        let previousID = "setContainerPrimarySpan.decrease10Percent"
        let currentID = "resizeContainerPrimarySpan.shrink"
        let validAlias = addingHotkey(id: previousID, binding: "Option+L", to: original)
        let valid = try SettingsTOMLCodec.decodeForLoad(validAlias)

        XCTAssertEqual(valid.export.hotkeyBindings, SettingsExport.defaults().hotkeyBindings)
        XCTAssertEqual(valid.migration?.mappedHotkeys, [
            SettingsHotkeyMapping(
                previousID: previousID,
                currentID: currentID,
                keptExplicitCurrentBinding: true
            )
        ])

        for bindingLine in ["binding = \"NotAKey\"", "binding = 17"] {
            let data = Data((String(decoding: original, as: UTF8.self) + "\n\n[[hotkeys]]\n"
                    + "id = \"\(previousID)\"\n\(bindingLine)\n").utf8)
            XCTAssertThrowsError(try SettingsTOMLCodec.decodeForLoad(data), bindingLine) { error in
                XCTAssertTrue(SettingsTOMLCodec.diagnosticDescription(for: error).contains("hotkeys["))
            }
        }
    }

    func testVersionTwoRoutingMigrationRejectsMissingMalformedArraysAndRowsWithoutChangingBytes() throws {
        let valid = String(decoding: try versionTwoData(), as: UTF8.self)
        let inputs = [
            valid.replacingOccurrences(of: "monitorRoutingOverrides = []\n", with: ""),
            valid.replacingOccurrences(of: "monitorRoutingOverrides = []", with: "monitorRoutingOverrides = 3"),
            valid.replacingOccurrences(of: "monitorRoutingOverrides = []", with: "monitorRoutingOverrides = {}"),
            valid.replacingOccurrences(of: "monitorRoutingOverrides = []", with: "monitorRoutingOverrides = [3]"),
            valid.replacingOccurrences(
                of: "monitorRoutingOverrides = []",
                with: "monitorRoutingOverrides = [{ monitorName = \"Laptop\", gridColumn = 0 }]"
            ),
            valid.replacingOccurrences(
                of: "monitorRoutingOverrides = []",
                with: "monitorRoutingOverrides = [{ monitorName = \"Laptop\", gridColumn = 0, gridRow = 0, monitorDisplayUUID = \"bad\" }]"
            )
        ]
        for (index, input) in inputs.enumerated() {
            let data = Data(input.utf8)
            XCTAssertThrowsError(try SettingsTOMLCodec.decodeForLoad(data), "case \(index)")
        }
    }

    func testVersionTwoRoutingMigrationRejectsExistingArrangementsWithoutChangingBytes() throws {
        let original = String(decoding: try versionTwoData(routingRows: """
        [[monitorRoutingOverrides]]
        monitorName = "Laptop"
        monitorDisplayId = 7
        gridColumn = 0
        gridRow = 0
        """), as: UTF8.self)
        let conflicting = original.replacingOccurrences(
            of: "[routing]\n",
            with: "[routing]\narrangements = []\n"
        )
        XCTAssertNotEqual(conflicting, original)
        let data = Data(conflicting.utf8)
        XCTAssertThrowsError(try SettingsTOMLCodec.decodeForLoad(data)) { error in
            XCTAssertTrue(SettingsTOMLCodec.diagnosticDescription(for: error).contains("routing.arrangements"))
        }
    }

    func testMalformedVersionOneFilesAreRejectedWithoutChangingBytesOrCreatingBackups() throws {
        let valid = try legacyFixtureData(named: "v0.6.4-custom")
        let validText = String(decoding: valid, as: UTF8.self)
        let missingAction = try removingHotkey(id: "swapSplit", from: valid)
        let duplicateAction = addingHotkey(id: "swapSplit", binding: "Unassigned", to: valid)
        let unknownAction = addingHotkey(id: "retired.action", binding: "Unassigned", to: valid)
        let partialEntry = Data(validText.replacingOccurrences(
            of: "futureHotkeySetting = \"keep-by-id\"\nid = \"swapSplit\"",
            with: "futureHotkeySetting = \"keep-by-id\""
        ).utf8)
        let invalidEnum = Data(validText.replacingOccurrences(
            of: "defaultLayoutType = \"dwindle\"",
            with: "defaultLayoutType = \"invalid\""
        ).utf8)
        let malformedTrigger = Data(validText.replacingOccurrences(
            of: "binding = \"Option+J\"\nfutureHotkeySetting = \"keep-by-id\"\nid = \"swapSplit\"",
            with: "binding = \"NotAKey\"\nfutureHotkeySetting = \"keep-by-id\"\nid = \"swapSplit\""
        ).utf8)
        XCTAssertEqual(
            try hotkey("swapSplit", in: SettingsTOMLCodec.decodeForLoad(missingAction).export)?.binding,
            .unassigned
        )
        let cases = [
            ("duplicate", duplicateAction),
            ("unknown", unknownAction),
            ("partial", partialEntry),
            ("enum", invalidEnum),
            ("trigger", malformedTrigger)
        ]

        for (name, data) in cases {
            XCTAssertNotEqual(data, valid, name)
            XCTAssertThrowsError(try SettingsTOMLCodec.decodeForLoad(data), name)
        }
    }

    func testExplicitSlotOneBindingsWinOverLegacyAliases() throws {
        var data = try legacyFixtureData(named: "v0.6.3-custom")
        data = addingHotkey(id: "assignFocusedWindowToScratchpad.1", binding: "Option+L", to: data)
        data = addingHotkey(id: "toggleScratchpad.1", binding: "Option+M", to: data)

        let result = try SettingsTOMLCodec.decodeForLoad(data)
        let migration = try XCTUnwrap(result.migration)

        XCTAssertEqual(
            hotkey("assignFocusedWindowToScratchpad.1", in: result.export)?.binding.humanReadableString,
            "Option+L"
        )
        XCTAssertEqual(
            hotkey("toggleScratchpad.1", in: result.export)?.binding.humanReadableString,
            "Option+M"
        )
        XCTAssertEqual(
            migration.mappedHotkeys,
            [
                SettingsHotkeyMapping(
                    previousID: "assignFocusedWindowToScratchpad",
                    currentID: "assignFocusedWindowToScratchpad.1",
                    keptExplicitCurrentBinding: true
                ),
                SettingsHotkeyMapping(
                    previousID: "toggleScratchpadWindow",
                    currentID: "toggleScratchpad.1",
                    keptExplicitCurrentBinding: true
                )
            ] + expectedVersionFiveMappings
        )
    }

    func testVersionOneFixtureAddsCurrentBindingsAndPreservesCustomDataByID() throws {
        let originalData = try legacyFixtureData(named: "v0.6.4-custom")
        let result = try SettingsTOMLCodec.decodeForLoad(originalData)
        let migration = try XCTUnwrap(result.migration)
        let migratedData = try XCTUnwrap(result.migratedData)

        XCTAssertEqual(migration.fromVersion, 1)
        XCTAssertEqual(migration.toVersion, 5)
        XCTAssertEqual(migration.addedHotkeyIDs.count, 21)
        XCTAssertEqual(
            Set(migration.addedHotkeyIDs),
            expectedVersionTwoHotkeyIDs.union(expectedVersionFourHotkeyIDs)
        )
        XCTAssertEqual(migration.defaultedPaths, ["routing.arrangements"])
        XCTAssertEqual(migration.mappedHotkeys, expectedVersionFiveMappings)
        XCTAssertTrue(migration.retiredHotkeys.isEmpty)
        XCTAssertEqual(
            result.export,
            try SettingsTOMLCodec.decodeForLoad(legacyFixtureData(named: "v0.6.3-custom")).export
        )
        for id in expectedVersionTwoHotkeyIDs {
            XCTAssertTrue(hotkey(id, in: result.export)?.binding.isUnassigned == true, id)
        }

        XCTAssertTrue(result.export.focus.followsMouse)
        XCTAssertFalse(result.export.focus.raiseOnMouseFocus)
        XCTAssertEqual(result.export.gaps.size, 27)
        XCTAssertTrue(result.export.gaps.fullscreenUsesOuterGaps)
        XCTAssertEqual(result.export.defaultLayoutType, .dwindle)
        XCTAssertEqual(result.export.workspaceBar.excludedBundleIDs, ["com.example.Hidden"])
        XCTAssertEqual(hotkey("swapSplit", in: result.export)?.binding.humanReadableString, "Option+J")
        XCTAssertEqual(
            hotkey("assignFocusedWindowToScratchpad.1", in: result.export)?.binding.humanReadableString,
            "Option+J"
        )
        XCTAssertEqual(
            hotkey("toggleScratchpad.1", in: result.export)?.binding.humanReadableString,
            "Option+K"
        )

        let workspace = try XCTUnwrap(result.export.workspaceConfigurations.only)
        XCTAssertEqual(workspace.id.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(workspace.name, "dev")
        XCTAssertEqual(workspace.displayName, "Development")
        XCTAssertEqual(workspace.monitorAssignment, .secondary)
        XCTAssertEqual(workspace.layoutType, .dwindle)

        let rule = try XCTUnwrap(result.export.appRules.only)
        XCTAssertEqual(rule.id.uuidString, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(rule.bundleId, "com.example.Terminal")
        XCTAssertEqual(rule.titleRegex, "^Project")
        XCTAssertEqual(rule.layout, .float)
        XCTAssertEqual(rule.assignToWorkspace, "dev")
        XCTAssertEqual(rule.initialContainerPrimarySpan, 0.65)
        XCTAssertEqual(rule.minWidth, 720)
        XCTAssertEqual(rule.minHeight, 480)

        let currentIDs = HotkeyBindingRegistry.defaults().map(\.id)
        let renamedIDs = Dictionary(uniqueKeysWithValues: expectedVersionFiveMappings.map {
            ($0.previousID, $0.currentID)
        })
        let persistedIDs = Set(hotkeyIDs(in: originalData).map { renamedIDs[$0] ?? $0 })
            .union(expectedVersionTwoHotkeyIDs)
            .union(expectedVersionFourHotkeyIDs)
        XCTAssertEqual(Set(hotkeyIDs(in: migratedData)), persistedIDs)
        XCTAssertEqual(hotkeyIDs(in: migratedData), currentIDs.filter { persistedIDs.contains($0) })
        for id in Set(currentIDs).subtracting(persistedIDs) {
            let expected = HotkeyBindingRegistry.idsGivenTheirDefaultWhenMissing.contains(id)
                ? HotkeyBindingRegistry.defaultBinding(for: id)?.binding
                : .unassigned
            XCTAssertEqual(hotkey(id, in: result.export)?.binding, expected, id)
        }
        let markerSections = hotkeySections(in: migratedData).filter {
            $0.contains("futureHotkeySetting = \"keep-by-id\"")
        }
        XCTAssertEqual(markerSections.count, 1)
        XCTAssertEqual(markerSections.first.flatMap(hotkeyID(in:)), "swapSplit")
        let unknownPaths = SettingsTOMLCodec.unknownKeyPaths(in: migratedData)
        XCTAssertTrue(unknownPaths.contains("general.futureSetting"))
        XCTAssertTrue(unknownPaths.contains("futureExtension"))
        XCTAssertEqual(unknownPaths.filter { $0.hasSuffix(".futureHotkeySetting") }.count, 1)
    }

    func testVersionOneMigrationPreservesAnAlreadyPresentVersionTwoBinding() throws {
        let data = addingHotkey(
            id: "closeFocusedWindow",
            binding: "Option+W",
            to: try legacyFixtureData(named: "v0.6.4-custom")
        )

        let result = try SettingsTOMLCodec.decodeForLoad(data)
        let migration = try XCTUnwrap(result.migration)

        XCTAssertEqual(migration.fromVersion, 1)
        XCTAssertEqual(migration.addedHotkeyIDs.count, 20)
        XCTAssertEqual(
            Set(migration.addedHotkeyIDs),
            expectedVersionTwoHotkeyIDs.subtracting(["closeFocusedWindow"])
                .union(expectedVersionFourHotkeyIDs)
        )
        XCTAssertEqual(
            hotkey("closeFocusedWindow", in: result.export)?.binding.humanReadableString,
            "Option+W"
        )
    }

    func testVersionZeroMigrationStillRejectsUnknownAndDuplicateHotkeys() throws {
        let fixture = try legacyFixtureData(named: "v0.6.3-custom")
        let unknown = addingHotkey(id: "retired.action", binding: "Unassigned", to: fixture)
        XCTAssertThrowsError(try SettingsTOMLCodec.decodeForLoad(unknown)) { error in
            XCTAssertEqual(error as? HotkeyBindingResolutionError, .unknownActionID("retired.action"))
        }

        let duplicate = addingHotkey(id: "swapSplit", binding: "Unassigned", to: fixture)
        XCTAssertThrowsError(try SettingsTOMLCodec.decodeForLoad(duplicate)) { error in
            XCTAssertEqual(error as? HotkeyBindingResolutionError, .duplicateActionID("swapSplit"))
        }
    }

    func testVersionZeroMigrationStillRejectsMalformedTriggersTypesAndValues() throws {
        let fixture = String(decoding: try legacyFixtureData(named: "v0.6.3-custom"), as: UTF8.self)
        let retiredFixture = String(decoding: try legacyFixtureData(named: "v0.6.2-custom"), as: UTF8.self)
        let ignoredAlias = String(decoding: addingHotkey(
            id: "assignFocusedWindowToScratchpad.1",
            binding: "Option+L",
            to: Data(fixture.replacingOccurrences(
                of: "binding = \"Option+J\"\nid = \"assignFocusedWindowToScratchpad\"",
                with: "binding = \"NotAKey\"\nid = \"assignFocusedWindowToScratchpad\""
            ).utf8)
        ), as: UTF8.self)
        let cases = [
            (
                fixture.replacingOccurrences(
                    of: "binding = \"Option+J\"\nid = \"assignFocusedWindowToScratchpad\"",
                    with: "binding = \"NotAKey\"\nid = \"assignFocusedWindowToScratchpad\""
                ),
                "hotkeys["
            ),
            (
                fixture.replacingOccurrences(of: "followsMouse = true", with: "followsMouse = \"true\""),
                "focus.followsMouse"
            ),
            (
                fixture.replacingOccurrences(
                    of: "systemHyperTrigger = \"None\"",
                    with: "systemHyperTrigger = \"Nope\""
                ),
                "general.systemHyperTrigger"
            ),
            (
                retiredFixture.replacingOccurrences(
                    of: "binding = \"Unassigned\"\nid = \"consumeOrExpelWindowLeft\"",
                    with: "binding = \"NotAKey\"\nid = \"consumeOrExpelWindowLeft\""
                ),
                "hotkeys["
            ),
            (
                ignoredAlias,
                "hotkeys["
            )
        ]

        for (source, expectedPath) in cases {
            XCTAssertThrowsError(try SettingsTOMLCodec.decodeForLoad(Data(source.utf8))) { error in
                XCTAssertTrue(
                    SettingsTOMLCodec.diagnosticDescription(for: error).contains(expectedPath),
                    "Expected \(expectedPath), got \(SettingsTOMLCodec.diagnosticDescription(for: error))"
                )
            }
        }
    }

    func testCurrentSchemaIsEncodedAndFutureSchemaIsRejectedExplicitly() throws {
        let canonical = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        XCTAssertTrue(canonical.contains("schemaVersion = 5"))
        let future = canonical.replacingOccurrences(of: "schemaVersion = 5", with: "schemaVersion = 6")
        XCTAssertNotEqual(future, canonical)

        XCTAssertThrowsError(try SettingsTOMLCodec.decodeForLoad(Data(future.utf8))) { error in
            XCTAssertEqual(
                error as? SettingsTOMLCodecError,
                .unsupportedSchemaVersion(found: 6, supported: 5)
            )
        }
    }

    private var expectedAddedHotkeyIDs: Set<String> {
        Set((2 ... 10).flatMap { index in
            ["toggleScratchpad.\(index)", "assignFocusedWindowToScratchpad.\(index)"]
        })
        .union(expectedVersionTwoHotkeyIDs)
        .union(expectedVersionFourHotkeyIDs)
    }

    private var expectedVersionFourHotkeyIDs: Set<String> {
        ["setWindowMark", "removeWindowMark"]
    }

    private var expectedVersionFiveMappings: [SettingsHotkeyMapping] {
        [
            ("setContainerPrimarySpan.decrease10Percent", "resizeContainerPrimarySpan.shrink"),
            ("setContainerPrimarySpan.increase10Percent", "resizeContainerPrimarySpan.grow"),
            ("setWindowPrimarySpan.decrease10Percent", "resizeWindowPrimarySpan.shrink"),
            ("setWindowPrimarySpan.increase10Percent", "resizeWindowPrimarySpan.grow"),
            ("setWindowSecondarySpan.decrease10Percent", "resizeWindowSecondarySpan.shrink"),
            ("setWindowSecondarySpan.increase10Percent", "resizeWindowSecondarySpan.grow")
        ].map { SettingsHotkeyMapping(previousID: $0, currentID: $1, keptExplicitCurrentBinding: false) }
    }

    private var expectedVersionTwoHotkeyIDs: Set<String> {
        Set((1 ... 9).flatMap { slot in
            ["switchWorkspaceSlot.\(slot)", "moveToWorkspaceSlot.\(slot)"]
        }).union(["closeFocusedWindow"])
    }

    private func hotkey(_ id: String, in export: SettingsExport) -> HotkeyBinding? {
        export.hotkeyBindings.first { $0.id == id }
    }

    private func addingHotkey(id: String, binding: String, to data: Data) -> Data {
        var text = String(decoding: data, as: UTF8.self)
        text += "\n\n[[hotkeys]]\n"
        text += "binding = \"\(binding)\"\n"
        text += "id = \"\(id)\"\n"
        return Data(text.utf8)
    }

    private func hotkeySections(in data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .components(separatedBy: "[[hotkeys]]")
            .dropFirst()
            .map { $0 }
    }

    private func hotkeyID(in section: String) -> String? {
        let prefix = "id = \""
        guard let line = section.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }),
              line.hasSuffix("\"")
        else {
            return nil
        }
        return String(line.dropFirst(prefix.count).dropLast())
    }

    private func hotkeyIDs(in data: Data) -> [String] {
        hotkeySections(in: data).compactMap(hotkeyID(in:))
    }

    private func hotkeySection(id: String, in data: Data) throws -> String {
        try XCTUnwrap(hotkeySections(in: data).first { hotkeyID(in: $0) == id })
    }

    private func removingHotkey(id: String, from data: Data) throws -> Data {
        var sections = String(decoding: data, as: UTF8.self).components(separatedBy: "[[hotkeys]]")
        let index = try XCTUnwrap(sections.indices.dropFirst().first { hotkeyID(in: sections[$0]) == id })
        sections.remove(at: index)
        return Data(sections.joined(separator: "[[hotkeys]]").utf8)
    }

    private func version060DirectionalResizeData(from data: Data) throws -> Data {
        var text = String(decoding: data, as: UTF8.self)
        let replacements = [
            ("resizeGrow.horizontal", ["resizeGrow.left", "resizeGrow.right"]),
            ("resizeGrow.vertical", ["resizeGrow.up", "resizeGrow.down"]),
            ("resizeShrink.horizontal", ["resizeShrink.left", "resizeShrink.right"]),
            ("resizeShrink.vertical", ["resizeShrink.up", "resizeShrink.down"])
        ]
        for (currentID, previousIDs) in replacements {
            let current = "[[hotkeys]]\nbinding = \"Unassigned\"\nid = \"\(currentID)\""
            guard text.contains(current) else {
                throw NSError(domain: "SettingsMigrationTests", code: 1)
            }
            let previous = previousIDs.map { id in
                "[[hotkeys]]\nbinding = \"Unassigned\"\nid = \"\(id)\""
            }.joined(separator: "\n\n")
            text = text.replacingOccurrences(of: current, with: previous)
        }
        return Data(text.utf8)
    }

    private func versionTwoData(routingRows: String = "") throws -> Data {
        var export = SettingsExport.defaults()
        export.routing.mode = .custom
        export.gaps.size = 27
        let canonical = String(decoding: try SettingsTOMLCodec.encode(export), as: UTF8.self)
            .replacingOccurrences(of: "schemaVersion = 5", with: "schemaVersion = 2")
            .replacingOccurrences(of: "arrangements = []\n", with: "")
        if routingRows.isEmpty {
            return Data(("monitorRoutingOverrides = []\n" + canonical).utf8)
        }
        return Data((canonical + "\n" + routingRows + "\n").utf8)
    }

    private func legacyFixtureData(named name: String) throws -> Data {
        let resources = try XCTUnwrap(Bundle.module.resourceURL)
        return try Data(contentsOf: resources
            .appendingPathComponent("Fixtures/Settings", isDirectory: true)
            .appendingPathComponent("\(name).toml", isDirectory: false))
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
