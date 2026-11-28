// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class SettingsListOwnerTests: XCTestCase {
    func testHandOrderedWorkspaceFilePreservesOtherRowsOnRenameAddAndDelete() throws {
        var renamed = WorkspaceConfiguration(name: "8", displayName: "Notes")
        let removed = WorkspaceConfiguration(name: "1")
        let retained = WorkspaceConfiguration(name: "4")
        let added = WorkspaceConfiguration(name: "2")
        let removedComment = "-- leave this comment here"
        let first = workspaceRow(renamed, comment: "-- my notes")
        let second = workspaceRow(removed, comment: removedComment)
        let third = "\t" + workspaceRow(retained, comment: "-- keep its indentation")
        let header = "return { workspaces = {\n"
        let footer = "\n} }\n"
        let original = header + [first, second, third].joined(separator: "\n") + footer
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try makeStore(in: directory, source: Data(original.utf8))
        func contents() throws -> String {
            try String(contentsOf: settings.settingsFileURL, encoding: .utf8)
        }

        XCTAssertEqual(settings.workspaces.configurations, [removed, retained, renamed])
        let index = try XCTUnwrap(settings.workspaces.configurations.firstIndex { $0.id == renamed.id })
        renamed.displayName = "Research"
        settings.workspaces.configurations[index] = renamed
        let edited = original.replacingOccurrences(of: "'Notes'", with: #""Research""#)
        XCTAssertEqual(try contents(), edited)

        settings.workspaces.configurations = (settings.workspaces.configurations + [added])
            .sorted { $0.sortOrder < $1.sortOrder }
        let appended = try contents()
        XCTAssertTrue(appended.hasPrefix(String(edited.dropLast(footer.count)) + "\n"), appended)
        XCTAssertTrue(appended.hasSuffix(footer), appended)
        XCTAssertEqual(
            try SettingsLuauDocument(Data(appended.utf8)).export.workspaceConfigurations,
            [renamed, removed, retained, added]
        )

        settings.workspaces.configurations.removeAll { $0.id == removed.id }
        XCTAssertNil(settings.configNotice)
        XCTAssertEqual(try contents(), appended.replacingOccurrences(of: second, with: "    " + removedComment))
        XCTAssertEqual(try makeStore(in: directory).workspaces.configurations, [added, retained, renamed])
    }

    func testSortedWorkspaceFileInsertsBetweenNamesAndRetainsOriginalRows() throws {
        let first = WorkspaceConfiguration(name: "2")
        let last = WorkspaceConfiguration(name: "10")
        let added = WorkspaceConfiguration(name: "5")
        for (firstKey, lastKey) in [("", ""), ("[0x2] = ", "[1] = ")] {
            let firstRow = workspaceRow(first, key: firstKey, comment: "-- before")
            let lastRow = workspaceRow(last, key: lastKey, comment: "-- after")
            let prefix = "return { workspaces = {\n" + firstRow + "\n"
            let suffix = lastRow + "\n} }\n"
            let original = prefix + suffix
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let settings = try makeStore(in: directory, source: Data(original.utf8))
            settings.workspaces.configurations = [first, added, last]
            XCTAssertNil(settings.configNotice)
            let saved = try String(contentsOf: settings.settingsFileURL, encoding: .utf8)
            XCTAssertTrue(saved.hasPrefix(prefix), saved)
            XCTAssertTrue(saved.hasSuffix("\n" + suffix), saved)
            XCTAssertEqual(try makeStore(in: directory).workspaces.configurations, [first, added, last])
            settings.workspaces.configurations.removeAll { $0.id == added.id }
            XCTAssertEqual(try String(contentsOf: settings.settingsFileURL, encoding: .utf8), original)
        }
    }

    private func workspaceRow(_ workspace: WorkspaceConfiguration, key: String = "", comment: String) -> String {
        let displayName = workspace.displayName.map { "displayName = '\($0)', " } ?? ""
        return "    " + key + "{ id = '\(workspace.id)', name = '\(workspace.name)', " + displayName
            + "monitorAssignment = { type = 'main' }, layoutType = 'default' }, " + comment
    }

    func testEditingSavedShortcutsAndRulesExcludesScriptEntriesFromBothLists() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try makeStore(in: directory, source: SettingsLuauDocument.initialSource(.defaults()))
        let script = ConfigScriptController(
            fileURL: directory.appendingPathComponent("init.luau"),
            settings: settings
        ) {
            _ in
        }
        let scriptBundle = "example.script"
        let source = """
        omniwm.keymap.set('Control+Option+J', omniwm.cmd.openCommandPalette())
        omniwm.rule { bundleId = '\(scriptBundle)', layout = 'float' }
        """
        let mask = settings.hyperKeyModifiers.carbonMask
        let evaluation = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: mask)
        XCTAssertTrue(script.apply(.init(versions: [:], result: .success(evaluation)), hyperMask: mask))
        let scriptShortcut = try XCTUnwrap(script.effectiveBindings.first)
        XCTAssertTrue(settings.effectiveAppRules.contains { $0.bundleId == scriptBundle })
        let shortcut = try XCTUnwrap(settings.hotkeyBindings.first { !$0.binding.isUnassigned })
        settings.clearBinding(for: shortcut.id)
        let rule = AppRule(bundleId: "example.saved", layout: .tile)
        settings.appRules.append(rule)
        XCTAssertNil(settings.configNotice)
        let saved = try SettingsLuauDocument(Data(contentsOf: settings.settingsFileURL)).export
        XCTAssertTrue(try XCTUnwrap(saved.hotkeyBindings.first { $0.id == shortcut.id }).binding.isUnassigned)
        XCTAssertFalse(saved.hotkeyBindings.contains { $0.id == scriptShortcut.id })
        XCTAssertTrue(saved.appRules.contains(rule))
        XCTAssertFalse(saved.appRules.contains { $0.bundleId == scriptBundle })
    }

    func testDeletingFirstEqualPresetKeepsTheSecondSourceRow() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lines = [
            "return { niri = { containerPrimarySpanPresets = {",
            "    0.50, -- remove this preset",
            "    .5, -- keep this preset",
            "    .75,",
            "} } }"
        ]
        let settings = try makeStore(in: directory, source: Data(lines.joined(separator: "\n").utf8))
        let first = settings.niri.containerPrimarySpanPresets.startIndex
        let survivors = settings.niri.containerPrimarySpanPresets.indices.dropFirst()
        let expected = Array(settings.niri.containerPrimarySpanPresets.dropFirst())
        settings.editList(at: ["niri", "containerPrimarySpanPresets"], keeping: survivors.map(Optional.some)) {
            settings.niri.containerPrimarySpanPresets.remove(at: first)
        }
        XCTAssertNil(settings.configNotice)
        let saved = try String(contentsOf: settings.settingsFileURL, encoding: .utf8)
        XCTAssertTrue(saved.contains(".5, -- keep this preset"), saved)
        XCTAssertTrue(saved.contains("-- remove this preset"), saved)
        XCTAssertFalse(saved.contains("0.50,"), saved)
        XCTAssertEqual(try SettingsLuauDocument(Data(saved.utf8)).export.niri.containerPrimarySpanPresets, expected)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeStore(in directory: URL, source: Data? = nil) throws -> SettingsStore {
        let storage = SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false)
        if let source { try source.write(to: storage.fileURL) }
        return SettingsStore(persistence: storage, runtimeState: RuntimeStateStore(directory: directory))
    }
}
