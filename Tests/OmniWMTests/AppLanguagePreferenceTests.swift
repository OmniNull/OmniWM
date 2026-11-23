// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class AppLanguagePreferenceTests: XCTestCase {
    func testLanguagePersistsInSettingsFileAndIsReadAtLaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false)
        )
        XCTAssertNil(settings.language)
        XCTAssertNil(AppLanguagePreference.configuredLanguage(in: settings.settingsFileURL))

        settings.language = "sr-Latn"

        let text = try String(contentsOf: settings.settingsFileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("language = \"sr-Latn\""))
        XCTAssertEqual(try SettingsLuauDocument(Data(text.utf8)).export.language, "sr-Latn")
        XCTAssertEqual(AppLanguagePreference.configuredLanguage(in: settings.settingsFileURL), "sr-Latn")

        settings.language = nil

        XCTAssertNil(try SettingsLuauDocument(Data(contentsOf: settings.settingsFileURL)).export.language)
        XCTAssertNil(AppLanguagePreference.configuredLanguage(in: settings.settingsFileURL))
    }

    func testMissingSettingsFileFollowsMacOS() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(SettingsFilePersistence.fileName)

        XCTAssertNil(AppLanguagePreference.configuredLanguage(in: fileURL))
    }

    func testConfiguredLanguageOverridesOnlyTheAppleLanguagesLaunchArgument() throws {
        let arguments = try XCTUnwrap(
            AppLanguagePreference.launchArguments(["NSSurroundLocalizedStrings": "YES"], selecting: "ja")
        )

        XCTAssertEqual(arguments["AppleLanguages"] as? [String], ["ja"])
        XCTAssertEqual(arguments["NSSurroundLocalizedStrings"] as? String, "YES")
        XCTAssertNil(AppLanguagePreference.launchArguments([:], selecting: nil))
        XCTAssertNil(AppLanguagePreference.launchArguments(["AppleLanguages": ["de"]], selecting: "ja"))
    }
}
