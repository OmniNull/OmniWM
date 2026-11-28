// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class TOMLSettingsTests: XCTestCase {
    func testLaunchAndStoreUseTheSettingsFileThatExists() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let toml = directory.appendingPathComponent("settings.toml")
        try Data("[general]\nlanguage = \"fr\"\n[gaps]\nsize = 37\n".utf8).write(to: toml)

        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        XCTAssertEqual(persistence.fileURL, toml)
        XCTAssertEqual(SettingsFilePersistence.launchLanguage(at: persistence.fileURL), "fr")
        let outcome = persistence.loadOutcome()
        XCTAssertNil(outcome.notice)
        XCTAssertEqual(outcome.export?.gaps.size, 37)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.luau").path))
    }

    func testLuauTakesPrecedenceAndLeavesTOMLAloneWhenBothFilesExist() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let toml = directory.appendingPathComponent("settings.toml")
        let original = Data("[gaps]\nsize = 37\n".utf8)
        try original.write(to: toml)
        try Data("return { gaps = { size = 29 } }\n".utf8).write(to: directory.appendingPathComponent("settings.luau"))

        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        var export = persistence.load()
        XCTAssertEqual(export.gaps.size, 29)
        export.gaps.size = 39
        try persistence.saveImmediately(export)
        XCTAssertEqual(try Data(contentsOf: toml), original)
    }

    func testAnAppEditKeepsUsingTOMLAndBacksUpTheOriginal() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.toml")
        let source = Data("[gaps]\nsize = 37 # my spacing\n".utf8)
        try source.write(to: file)

        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        var export = persistence.load()
        XCTAssertEqual(export.gaps.size, 37)
        export.gaps.size = 41
        try persistence.saveImmediately(export)
        export.gaps.size = 43
        try persistence.saveImmediately(export)

        let backup = directory.appendingPathComponent("settings.toml.before-omniwm-edit")
        XCTAssertEqual(try Data(contentsOf: backup), source)
        XCTAssertEqual(SettingsFilePersistence(directory: directory, startWatching: false).load().gaps.size, 43)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.luau").path))
    }

    func testLegacyTOMLReloadRetainsTheLastGoodSettingsOnError() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.toml")
        let legacy = """
        schemaVersion = 5
        [gaps]
        size = 37
        [appTheming.herdr]
        enabled = false
        [[hotkeys]]
        id = "toggleShellWidget.hidden-bar"
        binding = "Unassigned"
        modeKey = "a"
        """
        try Data(legacy.utf8).write(to: file)
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        let before = persistence.load()
        XCTAssertEqual(before.gaps.size, 37)
        let shortcut = try XCTUnwrap(before.hotkeyBindings.first { $0.id == "toggleShellWidget.hidden-bar" })
        XCTAssertNotNil(shortcut.modeKey)

        let invalid = Data("[gaps\n".utf8)
        try invalid.write(to: file, options: .atomic)
        let rejected = try XCTUnwrap(persistence.reloadOutcomeIfChanged())
        XCTAssertNotNil(rejected.notice)
        XCTAssertNil(rejected.export)
        XCTAssertEqual(try Data(contentsOf: file), invalid)

        try Data(legacy.replacingOccurrences(of: "37", with: "41").utf8).write(to: file, options: .atomic)
        let accepted = try XCTUnwrap(persistence.reloadOutcomeIfChanged())
        XCTAssertNil(accepted.notice)
        XCTAssertEqual(accepted.export?.gaps.size, 41)
    }

    func testAnOversizedAppEditPreservesThePreviousSettingsFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.toml")
        let original = Data("[gaps]\nsize = 37\n".utf8)
        try original.write(to: file)
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false)
        var export = persistence.load()
        export.workspaceConfigurations[0].displayName = String(repeating: "a", count: ConfigScriptLoader.sourceLimit)

        XCTAssertThrowsError(try persistence.saveImmediately(export))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
