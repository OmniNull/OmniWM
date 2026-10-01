// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import TOML

enum SettingsTOMLMigration {
    private static let versionOneHotkeyIDs = [
        "toggleScratchpad.1",
        "assignFocusedWindowToScratchpad.1",
        "toggleScratchpad.2",
        "assignFocusedWindowToScratchpad.2",
        "toggleScratchpad.3",
        "assignFocusedWindowToScratchpad.3",
        "toggleScratchpad.4",
        "assignFocusedWindowToScratchpad.4",
        "toggleScratchpad.5",
        "assignFocusedWindowToScratchpad.5",
        "toggleScratchpad.6",
        "assignFocusedWindowToScratchpad.6",
        "toggleScratchpad.7",
        "assignFocusedWindowToScratchpad.7",
        "toggleScratchpad.8",
        "assignFocusedWindowToScratchpad.8",
        "toggleScratchpad.9",
        "assignFocusedWindowToScratchpad.9",
        "toggleScratchpad.10",
        "assignFocusedWindowToScratchpad.10"
    ]

    private static let versionTwoHotkeyIDs = [
        "switchWorkspaceSlot.1",
        "moveToWorkspaceSlot.1",
        "switchWorkspaceSlot.2",
        "moveToWorkspaceSlot.2",
        "switchWorkspaceSlot.3",
        "moveToWorkspaceSlot.3",
        "switchWorkspaceSlot.4",
        "moveToWorkspaceSlot.4",
        "switchWorkspaceSlot.5",
        "moveToWorkspaceSlot.5",
        "switchWorkspaceSlot.6",
        "moveToWorkspaceSlot.6",
        "switchWorkspaceSlot.7",
        "moveToWorkspaceSlot.7",
        "switchWorkspaceSlot.8",
        "moveToWorkspaceSlot.8",
        "switchWorkspaceSlot.9",
        "moveToWorkspaceSlot.9",
        "closeFocusedWindow"
    ]

    static let hotkeyIDsAddedInVersionTwo = Set(versionTwoHotkeyIDs)

    private static let versionFourHotkeyIDs = [
        "setWindowMark",
        "removeWindowMark"
    ]

    static let hotkeyIDsAddedInVersionFour = Set(versionFourHotkeyIDs)

    private static let versionFiveHotkeyIDs = ["toggleAccordion"]

    static let hotkeyIDsAddedInVersionFive = Set(versionFiveHotkeyIDs)

    private struct PersistedHotkeyArray: Decodable {
        let hotkeys: [PersistedHotkeyBinding]
    }

    static func migrate(_ raw: inout [String: TOMLNode], from version: Int) throws -> SettingsMigrationReport {
        let versionOneReport = version == 0 ? try migrateVersionZero(&raw) : nil
        let versionTwoAddedHotkeyIDs = version <= 1 ? migrateVersionOne(&raw) : []
        let versionThreeDefaultedPaths = version <= 2 ? try migrateVersionTwo(&raw) : []
        let versionFourAddedHotkeyIDs = version <= 3 ? migrateVersionThree(&raw) : []
        let versionFiveAddedHotkeyIDs = version <= 4 ? migrateVersionFour(&raw) : []
        canonicalizeMigratedHotkeys(in: &raw)
        return SettingsMigrationReport(
            fromVersion: version,
            toVersion: SettingsTOMLCodec.currentSchemaVersion,
            defaultedPaths: (versionOneReport?.defaultedPaths ?? []) + versionThreeDefaultedPaths,
            addedHotkeyIDs: (versionOneReport?.addedHotkeyIDs ?? []) + versionTwoAddedHotkeyIDs
                + versionFourAddedHotkeyIDs + versionFiveAddedHotkeyIDs,
            mappedHotkeys: versionOneReport?.mappedHotkeys ?? [],
            retiredHotkeys: versionOneReport?.retiredHotkeys ?? []
        )
    }

    private static func migrateVersionZero(_ raw: inout [String: TOMLNode]) throws -> SettingsMigrationReport {
        var defaultedPaths: [String] = []
        if addMissingValue(
            in: &raw,
            table: "focus",
            key: "raiseOnMouseFocus",
            value: .boolean(true)
        ) {
            defaultedPaths.append("focus.raiseOnMouseFocus")
        }
        if addMissingValue(
            in: &raw,
            table: "gaps",
            key: "fullscreenUsesOuterGaps",
            value: .boolean(false)
        ) {
            defaultedPaths.append("gaps.fullscreenUsesOuterGaps")
        }
        if addMissingValue(
            in: &raw,
            table: "workspaceBar",
            key: "hideInNativeFullscreen",
            value: .boolean(false)
        ) {
            defaultedPaths.append("workspaceBar.hideInNativeFullscreen")
        }
        if raw["scratchpads"] == nil {
            raw["scratchpads"] = .table(["labels": .table([:])])
            defaultedPaths.append("scratchpads.labels")
        } else if addMissingValue(
            in: &raw,
            table: "scratchpads",
            key: "labels",
            value: .table([:])
        ) {
            defaultedPaths.append("scratchpads.labels")
        }

        stampMissingAppRuleIDs(in: &raw)
        let hotkeyResult = try migrateVersionZeroHotkeys(in: &raw)
        raw["schemaVersion"] = .integer(1)
        return SettingsMigrationReport(
            fromVersion: 0,
            toVersion: 1,
            defaultedPaths: defaultedPaths,
            addedHotkeyIDs: hotkeyResult.addedIDs,
            mappedHotkeys: hotkeyResult.mapped,
            retiredHotkeys: hotkeyResult.retired
        )
    }

    private static func addMissingValue(
        in raw: inout [String: TOMLNode],
        table tableKey: String,
        key: String,
        value: TOMLNode
    ) -> Bool {
        guard case .table(var table) = raw[tableKey], table[key] == nil else { return false }
        table[key] = value
        raw[tableKey] = .table(table)
        return true
    }

    private static func stampMissingAppRuleIDs(in raw: inout [String: TOMLNode]) {
        guard case let .array(entries) = raw["appRules"] else { return }
        raw["appRules"] = .array(entries.map { entry in
            guard case .table(var table) = entry, table["id"] == nil else { return entry }
            table["id"] = .string(UUID().uuidString)
            return .table(table)
        })
    }

    private static func migrateVersionZeroHotkeys(
        in raw: inout [String: TOMLNode]
    ) throws -> SettingsHotkeyMigrationResult {
        guard case let .array(entries) = raw["hotkeys"] else {
            return SettingsHotkeyMigrationResult(addedIDs: [], mapped: [], retired: [])
        }

        let decoder = TOMLDecoder()
        let validationData = try TOMLEncoder().encode(["hotkeys": TOMLNode.array(entries)])
        _ = try decoder.decode(PersistedHotkeyArray.self, from: validationData)
        let mappings = [
            "assignFocusedWindowToScratchpad": "assignFocusedWindowToScratchpad.1",
            "toggleScratchpadWindow": "toggleScratchpad.1"
        ]
        let retirements = [
            "consumeOrExpelWindowLeft": ["consumeWindowIntoColumn", "expelWindowFromColumn"],
            "consumeOrExpelWindowRight": ["consumeWindowIntoColumn", "expelWindowFromColumn"]
        ]
        let explicitCurrentIDs = Set(entries.compactMap(hotkeyID))
        var migrated = migrateLegacyHotkeyEntries(
            entries,
            explicitCurrentIDs: explicitCurrentIDs,
            mappings: mappings,
            retirements: retirements
        )
        let addedIDs = appendMissingUnassignedHotkeys(versionOneHotkeyIDs, to: &migrated.entries)
        raw["hotkeys"] = .array(migrated.entries)
        return SettingsHotkeyMigrationResult(
            addedIDs: addedIDs,
            mapped: migrated.mapped,
            retired: migrated.retired
        )
    }

    private static func migrateLegacyHotkeyEntries(
        _ entries: [TOMLNode],
        explicitCurrentIDs: Set<String>,
        mappings: [String: String],
        retirements: [String: [String]]
    ) -> SettingsHotkeyMigrationAccumulator {
        var result = SettingsHotkeyMigrationAccumulator(entries: [], mapped: [], retired: [])
        for entry in entries {
            guard let id = hotkeyID(entry) else {
                result.entries.append(entry)
                continue
            }
            if let suggestedIDs = retirements[id] {
                result.retired.append(SettingsRetiredHotkey(id: id, suggestedIDs: suggestedIDs))
                continue
            }
            guard let currentID = mappings[id] else {
                result.entries.append(entry)
                continue
            }
            let keepCurrent = explicitCurrentIDs.contains(currentID)
            result.mapped.append(SettingsHotkeyMapping(
                previousID: id,
                currentID: currentID,
                keptExplicitCurrentBinding: keepCurrent
            ))
            guard !keepCurrent, case .table(var table) = entry else { continue }
            table["id"] = .string(currentID)
            result.entries.append(.table(table))
        }
        return result
    }

    private static func migrateVersionOne(_ raw: inout [String: TOMLNode]) -> [String] {
        defer { raw["schemaVersion"] = .integer(2) }
        guard case var .array(entries) = raw["hotkeys"] else { return [] }

        let addedIDs = appendMissingUnassignedHotkeys(versionTwoHotkeyIDs, to: &entries)
        raw["hotkeys"] = .array(entries)
        return addedIDs
    }

    private static func migrateVersionTwo(_ raw: inout [String: TOMLNode]) throws -> [String] {
        struct PersistedRouting: Decodable {
            let monitorRoutingOverrides: [MonitorRoutingSettings]
        }

        let validationData = try TOMLEncoder().encode(raw)
        _ = try TOMLDecoder().decode(PersistedRouting.self, from: validationData)
        if case let .table(routing) = raw["routing"], routing["arrangements"] != nil {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [DynamicCodingKey("routing"), DynamicCodingKey("arrangements")],
                debugDescription: "Cannot migrate monitorRoutingOverrides while routing.arrangements already exists."
            ))
        }
        guard case let .array(rows) = raw.removeValue(forKey: "monitorRoutingOverrides") else {
            throw SettingsTOMLCodecError.migrationInvariant("Validated monitor routing rows are unavailable.")
        }
        let arrangements: [TOMLNode] = rows.isEmpty ? [] : [.table([
            "id": .string(UUID().uuidString),
            "monitors": .array(rows)
        ])]
        let added = addMissingValue(
            in: &raw,
            table: "routing",
            key: "arrangements",
            value: .array(arrangements)
        )
        raw["schemaVersion"] = .integer(3)
        return added ? ["routing.arrangements"] : []
    }

    private static func migrateVersionThree(_ raw: inout [String: TOMLNode]) -> [String] {
        defer { raw["schemaVersion"] = .integer(4) }
        guard case var .array(entries) = raw["hotkeys"] else { return [] }

        let addedIDs = appendMissingUnassignedHotkeys(versionFourHotkeyIDs, to: &entries)
        raw["hotkeys"] = .array(entries)
        return addedIDs
    }

    private static func migrateVersionFour(_ raw: inout [String: TOMLNode]) -> [String] {
        defer { raw["schemaVersion"] = .integer(5) }
        guard case var .array(entries) = raw["hotkeys"] else { return [] }

        let addedIDs = appendMissingUnassignedHotkeys(versionFiveHotkeyIDs, to: &entries)
        raw["hotkeys"] = .array(entries)
        return addedIDs
    }

    private static func appendMissingUnassignedHotkeys(
        _ ids: [String],
        to entries: inout [TOMLNode]
    ) -> [String] {
        let presentIDs = Set(entries.compactMap(hotkeyID))
        var addedIDs: [String] = []
        for id in ids where !presentIDs.contains(id) {
            entries.append(.table([
                "binding": .string("Unassigned"),
                "id": .string(id)
            ]))
            addedIDs.append(id)
        }
        return addedIDs
    }

    private static func canonicalizeMigratedHotkeys(in raw: inout [String: TOMLNode]) {
        guard case let .array(entries) = raw["hotkeys"] else { return }
        let order = Dictionary(
            uniqueKeysWithValues: HotkeyBindingRegistry.defaults().enumerated().map { ($1.id, $0) }
        )
        raw["hotkeys"] = .array(entries.enumerated().sorted { lhs, rhs in
            let lhsOrder = hotkeyID(lhs.element).flatMap { order[$0] } ?? Int.max
            let rhsOrder = hotkeyID(rhs.element).flatMap { order[$0] } ?? Int.max
            return lhsOrder == rhsOrder ? lhs.offset < rhs.offset : lhsOrder < rhsOrder
        }.map(\.element))
    }

    private static func hotkeyID(_ node: TOMLNode) -> String? {
        guard case let .table(table) = node, case let .string(id) = table["id"] else { return nil }
        return id
    }
}
