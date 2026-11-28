// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class SettingsListIdentityTests: XCTestCase {
    func testImplicitRuleIDsSurviveReloadAndReorderingAndDifferFromScriptRuleIDs() async throws {
        let explicit = UUID()
        let first = #"{ bundleId = "org.example.Editor", layout = "float" }"#
        let other = #"{ bundleId = "org.example.Browser", layout = "tile" }"#
        let named = #"{ id = "\#(explicit)", bundleId = "org.example.Music", layout = "float" }"#
        func load(_ rows: [String]) throws -> [UUID] {
            let source = "return { appRules = { " + rows.joined(separator: ", ") + " } }"
            return try SettingsLuauDocument(Data(source.utf8)).export.appRules.map(\.id)
        }
        let rows = [first, first, other, named]
        let ids = try load(rows)
        XCTAssertEqual(Set(ids).count, rows.count)
        XCTAssertEqual(ids.last, explicit)
        XCTAssertEqual(try load(rows), ids)
        XCTAssertEqual(try load([other, named, first, first]), [ids[2], explicit, ids[0], ids[1]])
        let script = rows.map { "omniwm.rule " + $0 }.joined(separator: "\n")
        let generation = try await ConfigScriptLoader().evaluate(Data(script.utf8), hyperMask: 0)
        let scriptIDs = Set(generation.rules.map(\.rule.id))
        XCTAssertEqual(Set(ids).intersection(scriptIDs), [explicit])
    }

    func testEntriesWithoutIDsCanBeLocatedByTheirNativeIDsAfterAnotherLoad() throws {
        let source = #"""
        return {
            launcher = { entries = { { name = string.upper("Editor") } } },
            appTheming = { custom = { { name = string.upper("Palette") } } },
        }
        """#
        let bytes = Data(source.utf8)
        let first = try SettingsLuauDocument(bytes)
        let second = try SettingsLuauDocument(bytes)
        let launcherID = try XCTUnwrap(first.export.launcher.entries.first?.id)
        let themeID = try XCTUnwrap(first.export.appTheming.custom.first?.id)
        XCTAssertEqual(second.export.launcher.entries.first?.id, launcherID)
        XCTAssertEqual(second.export.appTheming.custom.first?.id, themeID)
        let fields = SettingsFieldSources()
        fields.document = second
        for (id, key, expression) in [
            (launcherID.uuidString, SettingsFieldID.launcherEntries, #"string.upper("Editor")"#),
            (themeID, .appThemingCustom, #"string.upper("Palette")"#)
        ] {
            let site = try XCTUnwrap(fields.sites(for: [key], member: .row(id), leaves: ["name"]).first)
            XCTAssertEqual((source as NSString).substring(with: site.selection(in: bytes)), expression)
        }
    }

    func testNativeIDsMatchReorderedAndEditedRowsAndNeverClaimNewKeys() {
        let original = SettingsLuauValue.record(["id": .string("undo"), "binding": .string("Control+Z")])
        let changed = SettingsLuauValue.record(["id": .string("undo"), "binding": .string("Option+Z")])
        let inserted = SettingsLuauValue.record(["id": .string("redo"), "binding": .string("Option+Y")])
        XCTAssertEqual(
            SettingsListIdentity.match(path: ["hotkeys"], old: [original], new: [inserted, changed]),
            [nil, 0]
        )

        let path = ["routing", "arrangements", "0", "monitors"]
        let uuid = UUID().uuidString
        let monitor = SettingsLuauValue.record(["monitorDisplayUUID": .string(uuid), "monitorName": .string("Desk")])
        let renamed = SettingsLuauValue.record([
            "monitorDisplayUUID": .string(uuid.lowercased()),
            "monitorName": .string("Office")
        ])
        XCTAssertEqual(SettingsListIdentity.match(path: path, old: [monitor], new: [renamed]), [0])

        let principal: [String: SettingsLuauValue] = [
            "role": .string("component"),
            "name": .string("Weather"),
            "source": .string("local")
        ]
        var allowed = principal
        allowed["allowed"] = .list([.string("example.org")])
        XCTAssertEqual(SettingsListIdentity.match(
            path: ["shellPermissions", "widgets"],
            old: [.record(principal)],
            new: [.record(allowed)]
        ), [0])
    }

    func testEqualUnkeyedOccurrencesMoveSeparatelyAndEditedArgumentKeepsItsPosition() {
        let argument = SettingsLuauValue.string("repeat")
        let changed = SettingsLuauValue.string("changed")
        let marker = SettingsLuauValue.string("marker")
        let path = ["launcher", "entries", "0", "arguments"]
        XCTAssertEqual(
            SettingsListIdentity.match(path: path, old: [argument, argument], new: [changed, argument]),
            [0, 1]
        )
        XCTAssertEqual(SettingsListIdentity.match(
            path: path,
            old: [argument, marker, argument],
            new: [marker, argument, argument]
        ), [1, 0, 2])
        XCTAssertEqual(SettingsListIdentity.match(
            path: path,
            old: [argument, marker, argument],
            new: [argument, argument]
        ), [0, 2])
    }
}
