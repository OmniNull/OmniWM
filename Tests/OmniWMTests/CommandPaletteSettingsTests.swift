// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class CommandPaletteSettingsTests: XCTestCase {
    func testMissingTableTurnsUnifiedSearchOffWithDefaultSearchedModes() throws {
        let decoded = try SettingsTOMLCodec.decode(Data(removingCommandPaletteTable().utf8))

        XCTAssertFalse(decoded.commandPalette.unifiedSearch)
        XCTAssertEqual(decoded.commandPalette.searchedModes, [.windows, .applications, .commands, .files])
    }

    func testRoundTripKeepsUnifiedSearchAndSearchedModeOrder() throws {
        var settings = SettingsExport.defaults()
        settings.commandPalette.unifiedSearch = true
        settings.commandPalette.searchedModes = [.files, .clipboard, .windows]

        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(settings))

        XCTAssertEqual(decoded.commandPalette, settings.commandPalette)
    }

    func testUnknownAndDuplicateSearchedModesAreDropped() throws {
        let toml = try removingCommandPaletteTable() + """

        [commandPalette]
        unifiedSearch = true
        searchedModes = ["files", "everything", "windows", "files"]

        """

        let decoded = try SettingsTOMLCodec.decode(Data(toml.utf8))

        XCTAssertTrue(decoded.commandPalette.unifiedSearch)
        XCTAssertEqual(decoded.commandPalette.searchedModes, [.files, .windows])
    }

    @MainActor
    func testSettingsOwnerImportsAndExportsCommandPalette() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: directory.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        var export = SettingsExport.defaults()
        export.commandPalette.unifiedSearch = true
        export.commandPalette.searchedModes = [.menu, .commands]

        settings.applyExport(export)

        XCTAssertEqual(settings.commandPalette.export(), export.commandPalette)
        XCTAssertEqual(settings.toExport().commandPalette, export.commandPalette)
    }

    private func removingCommandPaletteTable() throws -> String {
        let encoded = try String(decoding: SettingsTOMLCodec.encode(SettingsExport.defaults()), as: UTF8.self)
        var inPaletteTable = false
        return encoded.components(separatedBy: "\n").filter { line in
            if line.hasPrefix("[") { inPaletteTable = line == "[commandPalette]" }
            return !inPaletteTable
        }.joined(separator: "\n")
    }
}
