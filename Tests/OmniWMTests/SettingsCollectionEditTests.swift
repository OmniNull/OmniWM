// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class SettingsCollectionEditTests: XCTestCase {
    func testReorderedRowsCarryTheirLeadingAndTrailingCommentsAndOnlyTheEditedValueChanges() throws {
        let first = UUID()
        let second = UUID()
        let before = "-- 🌙\r\nreturn { appRules = {\r\n"
        let after = "\r\n}, general = { language = 'sv' } }"
        let one = "\t-- first rule\r\n\t{ id = '\(first)', bundleId = 'One', layout = ('tile') }; -- first tail"
        let two = "\t-- second rule\r\n\t{ ['id'] = '\(second)', bundleId = 'Two', layout = 'float' }; -- second tail"
        let input = before + one + "\r\n" + two + after
        let document = try SettingsLuauDocument(Data(input.utf8))
        var desired = document.export
        desired.appRules.reverse()
        desired.appRules[0].layout = .tile
        let edit = try document.edit(from: document.export, to: desired)
        let expected = before + two.replacingOccurrences(of: "'float'", with: "\"tile\"") + "\r\n" + one + after
        XCTAssertEqual(String(decoding: edit.source, as: UTF8.self), expected)
        XCTAssertNil(edit.question)
        XCTAssertEqual(try SettingsLuauDocument(edit.source).export.appRules, desired.appRules)
    }

    func testRemovedRowLeavesAllItsNotesInPlaceAndAnInsertedRowUsesLocalIndentation() throws {
        let ids = (0 ..< 3).map { _ in UUID() }
        let source = """
        return { appRules = {
          { id = '\(ids[0])', bundleId = 'First' },
          -- old heading
          { id = '\(ids[1])', -- inner
            bundleId = 'Remove' }, -- old tail
          { id = '\(ids[2])', bundleId = 'Last' },
        } }
        """
        let document = try SettingsLuauDocument(Data(source.utf8))
        var desired = document.export
        desired.appRules.remove(at: 1)
        desired.appRules.append(AppRule(bundleId: "Inserted", layout: .float))
        let edit = try document.edit(from: document.export, to: desired)
        let saved = String(decoding: edit.source, as: UTF8.self)
        XCTAssertTrue(
            saved.contains("bundleId = 'First' },\n  -- old heading\n  -- inner\n  -- old tail\n  { id = '\(ids[2])'"),
            saved
        )
        XCTAssertTrue(saved.contains("\n  {\n    bundleId = \"Inserted\","), saved)
        XCTAssertFalse(saved.contains("'Remove'"), saved)
        XCTAssertNil(edit.question)
        XCTAssertEqual(try SettingsLuauDocument(edit.source).export.appRules, desired.appRules)
    }

    func testMissingIDStaysStableOnAFieldEditAndAfterDeletingAnEqualRow() throws {
        let row = "{ bundleId = 'Same', layout = 'float' }"
        let source = "return {appRules = {\n  \(row), -- A\n  \(row), -- B\n}}"
        let document = try SettingsLuauDocument(Data(source.utf8))
        var desired = document.export
        desired.appRules.removeFirst()
        let edit = try document.edit(from: document.export, to: desired)
        let saved = String(decoding: edit.source, as: UTF8.self)
        XCTAssertTrue(saved.contains("\n  -- A\n"))
        XCTAssertTrue(saved.contains("}, -- B"), saved)
        let survivor = try SettingsLuauDocument(edit.source)
        XCTAssertEqual(survivor.export.appRules, desired.appRules)
        desired.appRules[0].titleSubstring = "Document"
        let patched = try survivor.edit(from: survivor.export, to: desired)
        XCTAssertNil(patched.question)
        XCTAssertEqual(try SettingsLuauDocument(patched.source).export.appRules, desired.appRules)
    }

    func testMapUpdatesKeepKeySpellingCommentsAndSurvivingOrder() throws {
        let source = """
        return { workspaceBar = { iconOverrides = {
          ["com.App.First"] = 'one'; -- first icon
          ["com.App.Last"] = 'last'; -- last icon
        } } }
        """
        let document = try SettingsLuauDocument(Data(source.utf8))
        var desired = document.export
        desired.workspaceBar.iconOverrides["com.App.First"] = "changed"
        let patch = try document.edit(from: document.export, to: desired)
        XCTAssertEqual(
            String(decoding: patch.source, as: UTF8.self),
            source.replacingOccurrences(of: "'one'", with: "\"changed\"")
        )
        let intermediate = try SettingsLuauDocument(patch.source)
        desired.workspaceBar.iconOverrides.removeValue(forKey: "com.App.First")
        desired.workspaceBar.iconOverrides["com.New"] = "added"
        let second = try intermediate.edit(from: intermediate.export, to: desired)
        let saved = String(decoding: second.source, as: UTF8.self)
        XCTAssertTrue(saved.contains("\n  -- first icon\n  [\"com.App.Last\"] = 'last'; -- last icon"), saved)
        XCTAssertTrue(saved.contains("[\"com.New\"] = \"added\";"), saved)
        XCTAssertEqual(
            try SettingsLuauDocument(second.source).export.workspaceBar.iconOverrides,
            desired.workspaceBar.iconOverrides
        )
    }

    func testChangingOneMonitorOverrideDoesNotMaterializeOrReformatSiblings() throws {
        let original = 7
        let updated = original + 1
        let source = """
        return { monitorGapOverrides = {
          { monitorName = 'Built-in', id = '\(UUID())', innerGap = \(original) }, -- keep
        } }
        """
        let document = try SettingsLuauDocument(Data(source.utf8))
        var desired = document.export
        desired.monitorGapSettings[0].innerGap = Double(updated)
        let edit = try document.edit(from: document.export, to: desired)
        XCTAssertNil(edit.question)
        XCTAssertEqual(
            String(decoding: edit.source, as: UTF8.self),
            source.replacingOccurrences(of: "innerGap = \(original)", with: "innerGap = \(updated)")
        )
    }

    func testCalculatedListAndCalculatedRowPreviewTheirScopeAndCancelLeavesTheSourceAlone() throws {
        let local = "local function folders() return {'First', 'Second'} end\n"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SettingsFilePersistence(directory: root, startWatching: false, deferSaves: false)
        let source = Data((local + "return {launcher = {appFolders = folders()}}").utf8)
        try source.write(to: storage.fileURL)
        let settings = SettingsStore(persistence: storage, runtimeState: RuntimeStateStore(directory: root))
        storage.confirmation.canPresent = { true }
        var edited = settings.launcher
        edited.appFolders[0] = "Replacement"
        settings.launcher = edited
        let question = try XCTUnwrap(storage.confirmation.question)
        for preview in ["folders()", "Replacement", "Second"] { XCTAssertTrue(question.message.contains(preview)) }
        storage.confirmation.answer(question.id, replace: false)
        XCTAssertEqual(settings.launcher.appFolders, ["First", "Second"])
        XCTAssertEqual(try Data(contentsOf: storage.fileURL), source)
        settings.launcher = edited
        storage.confirmation.answer(try XCTUnwrap(storage.confirmation.question).id, replace: true)
        XCTAssertEqual(
            try SettingsLuauDocument(Data(contentsOf: storage.fileURL)).export.launcher.appFolders,
            edited.appFolders
        )

        let row = "local function rule() return {id = '\(UUID())', bundleId = 'One', layout = 'tile'} end\n"
        let other = "{id = '\(UUID())', bundleId = 'other'}"
        let document = try SettingsLuauDocument(Data((row + "return {appRules = {rule(), \(other)}}").utf8))
        var desired = document.export
        desired.appRules[0].layout = .float
        let patch = try document.edit(from: document.export, to: desired)
        let preview = try XCTUnwrap(patch.question)
        XCTAssertTrue(preview.contains("rule()"))
        XCTAssertTrue(preview.contains("One"))
        XCTAssertTrue(preview.contains("float"))
        XCTAssertFalse(preview.contains("other\""))
        XCTAssertTrue(String(decoding: patch.source, as: UTF8.self).contains(other))
    }
}

extension SettingsCollectionEditTests {
    func testSparseHotkeysKeepSourceOrderAndOnlyMaterializeTheEditedShortcut() throws {
        let source = "return { hotkeys = { {id='redo', binding='Unassigned'}, {id='undo',binding='Control+J'} } }"
        let document = try SettingsLuauDocument(Data(source.utf8))
        var desired = document.export
        let undo = try XCTUnwrap(desired.hotkeyBindings.firstIndex { $0.id == "undo" })
        desired.hotkeyBindings[undo].binding = .unassigned
        let edit = try document.edit(from: document.export, to: desired)
        XCTAssertEqual(
            String(decoding: edit.source, as: UTF8.self),
            source.replacingOccurrences(of: "'Control+J'", with: "\"Unassigned\"")
        )
        XCTAssertEqual(try SettingsLuauDocument(edit.source).export.hotkeyBindings, desired.hotkeyBindings)
        let other = try XCTUnwrap(desired.hotkeyBindings.firstIndex { $0.id != "undo" && $0.id != "redo" })
        desired.hotkeyBindings[other].binding = try XCTUnwrap(.fromHumanReadable("Control+Option+K"))
        let addition = try document.edit(from: document.export, to: desired)
        let candidate = try SettingsLuauDocument(addition.source)
        XCTAssertEqual(candidate.export.hotkeyBindings, desired.hotkeyBindings)
        guard case let .list(rows) = candidate.sourceValue["hotkeys"]
        else { return XCTFail("Expected saved shortcuts") }
        let ids = rows.compactMap { row -> String? in
            guard case let .string(id) = row["id"] else { return nil }
            return id
        }
        XCTAssertEqual(Set(ids), ["redo", "undo", desired.hotkeyBindings[other].id])
        XCTAssertEqual(ids.filter { $0 == "redo" || $0 == "undo" }, ["redo", "undo"])
    }

    func testStatusMenuRemovingANormalizedEntryDoesNotReviveADuplicate() throws {
        let source = """
        return { statusMenu = { hiddenControls = {
          ' One ', -- one
          'Two', -- two
          'One', -- also one
        } } }
        """
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SettingsFilePersistence(directory: root, startWatching: false, deferSaves: false)
        try Data(source.utf8).write(to: storage.fileURL)
        let settings = SettingsStore(persistence: storage, runtimeState: RuntimeStateStore(directory: root))
        settings.statusMenu.setControl("One", isVisible: true)
        XCTAssertNil(settings.configNotice)
        let saved = try String(contentsOf: storage.fileURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("\n  -- one\n  'Two', -- two\n  -- also one\n"), saved)
        let actual = try SettingsLuauDocument(Data(saved.utf8))
        XCTAssertEqual(actual.export.statusMenu.hiddenControls, ["Two"])
    }

    func testMovedTrailingLineCommentCannotSwallowAnInlineSibling() throws {
        let source = "return {launcher = {appFolders = {'A','B', -- B\n'C'}}}"
        let document = try SettingsLuauDocument(Data(source.utf8))
        var desired = document.export
        desired.launcher.appFolders.swapAt(0, 1)
        let edit = try document.edit(from: document.export, to: desired)
        let actual = try SettingsLuauDocument(edit.source)
        XCTAssertEqual(actual.export.launcher.appFolders, desired.launcher.appFolders)
        XCTAssertTrue(String(decoding: edit.source, as: UTF8.self).contains("'B', -- B\n"))
    }

    func testCoalescedFolderDeletionsRetainTheCorrectEqualOccurrence() throws {
        let rows = ["'D', -- first", "'D', -- second", "'D', -- third"]
        let source = "return {launcher = {appFolders = {\n  " + rows.joined(separator: "\n  ") + "\n}}}"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SettingsFilePersistence(directory: root, startWatching: false)
        try Data(source.utf8).write(to: storage.fileURL)
        let settings = SettingsStore(persistence: storage, runtimeState: RuntimeStateStore(directory: root))
        for _ in rows.dropLast() {
            let survivors = settings.launcher.appFolders.indices.dropFirst().map(Optional.some)
            settings
                .editList(at: ["launcher", "appFolders"], keeping: survivors) {
                    settings.launcher.appFolders.removeFirst()
                }
        }
        storage.flushNow()
        XCTAssertNil(settings.configNotice)
        let saved = try String(contentsOf: storage.fileURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("\n  -- first\n  -- second\n  'D', -- third"), saved)
    }
}

extension SettingsCollectionEditTests {
    func testAddingWorkspaceDoesNotWriteItsAutomaticallyCreatedShortcuts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false)
        try Data("return { workspaces = {} }".utf8).write(to: storage.fileURL)
        let settings = SettingsStore(persistence: storage, runtimeState: RuntimeStateStore(directory: directory))
        let name = String(ActionCatalog.digitCodes.count + 1)
        let workspace = WorkspaceConfiguration(name: name)
        let originals = settings.workspaces.configurations
        settings.workspaces.configurations.append(workspace)
        XCTAssertNil(settings.configNotice)
        let saved = try SettingsLuauDocument(Data(contentsOf: storage.fileURL))
        XCTAssertEqual(saved.export.workspaceConfigurations, originals + [workspace])
        XCTAssertNil(saved.sourceValue["hotkeys"])
    }
}

extension SettingsCollectionEditTests {
    func testCallReturningMultipleListRowsOffersFullListPreview() throws {
        let source = "local function folders() return 'First', 'Second' end\nreturn {launcher = {appFolders = {folders()}}}"
        let document = try SettingsLuauDocument(Data(source.utf8))
        var desired = document.export
        desired.launcher.appFolders.reverse()
        let edit = try document.edit(from: document.export, to: desired)
        let question = try XCTUnwrap(edit.question)
        XCTAssertTrue(question.contains("folders()"))
        XCTAssertTrue(question.contains("First"))
        XCTAssertTrue(question.contains("Second"))
        let candidate = try SettingsLuauDocument(edit.source)
        XCTAssertEqual(candidate.export.launcher.appFolders, desired.launcher.appFolders)
        XCTAssertNotNil(try edit.preview(candidate, applying: desired))
    }
}

extension SettingsCollectionEditTests {
    func testExplicitArrayIndicesKeepTheirKeySpellingOnEditAndRenumberOnMove() throws {
        let source = """
        return {launcher = {appFolders = {
          [0x2] = 'Second', -- second
          [1] = 'First', -- first
        }}}
        """
        let document = try SettingsLuauDocument(Data(source.utf8))
        var desired = document.export
        desired.launcher.appFolders[0] = "Edited"
        let field = try document.edit(from: document.export, to: desired)
        XCTAssertNil(field.question)
        XCTAssertEqual(
            String(decoding: field.source, as: UTF8.self),
            source.replacingOccurrences(of: "'First'", with: "\"Edited\"")
        )
        desired = document.export
        desired.launcher.appFolders.reverse()
        let move = try document.edit(from: document.export, to: desired)
        XCTAssertNil(move.question)
        let expected = source.replacingOccurrences(of: "[1]", with: "[2]").replacingOccurrences(
            of: "[0x2]",
            with: "[1]"
        )
        XCTAssertEqual(String(decoding: move.source, as: UTF8.self), expected)
        XCTAssertEqual(try SettingsLuauDocument(move.source).export.launcher.appFolders, desired.launcher.appFolders)
    }

    func testMixedExplicitAndPositionalArrayKeysStillDescribeTheEditedOrder() throws {
        let source = "return {launcher = {appFolders = {'First', [3] = 'Third', 'Second'}}}"
        let document = try SettingsLuauDocument(Data(source.utf8))
        var desired = document.export
        desired.launcher.appFolders.reverse()
        desired.launcher.appFolders.append("New")
        let edit = try document.edit(from: document.export, to: desired)
        XCTAssertNil(edit.question)
        XCTAssertEqual(try SettingsLuauDocument(edit.source).export.launcher.appFolders, desired.launcher.appFolders)
    }
}

extension SettingsCollectionEditTests {
    func testRemovingACalculatedRowPreviewsEffectsOnTheSurvivingRow() throws {
        let source = """
        local name = 'initial'
        local function first()
            name = 'changed'
            return 'First'
        end
        return { launcher = { appFolders = {first(), name} } }
        """
        let document = try SettingsLuauDocument(Data(source.utf8))
        var desired = document.export
        desired.launcher.appFolders.removeFirst()
        let patch = try document.edit(from: document.export, to: desired)
        let candidate = try SettingsLuauDocument(patch.source)
        let (message, result) = try XCTUnwrap(patch.preview(candidate, applying: desired))
        XCTAssertTrue(message.contains("first()"))
        XCTAssertTrue(message.contains("changed"))
        XCTAssertTrue(message.contains("initial"))
        XCTAssertEqual(result.launcher.appFolders, ["initial"])
        XCTAssertTrue(String(decoding: patch.source, as: UTF8.self).contains("{name}"))
    }
}
