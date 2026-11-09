// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellNotificationPreferencesTests: XCTestCase {
    private typealias Preferences = ShellNotificationPreferences

    private let allowed = ShellNotificationPreferences.notificationsAllowed
    private let hidden = ShellNotificationPreferences.hiddenFromNotificationCenter

    func testMissingMalformedAndUnsupportedFilesAreUnreadable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(Preferences(contentsOf: url))
        try notificationPreferences([]).write(to: url)
        XCTAssertNotNil(Preferences(contentsOf: url))
        try Data([1, 2, 3]).write(to: url)
        XCTAssertNil(Preferences(contentsOf: url))
        let entry: [String: Any] = ["bundle-id": "fixture", "flags": allowed]
        let roots: [[String: Any]] = [
            ["version": Preferences.supportedVersion + 1, "apps": [entry]],
            ["version": true, "apps": [entry]],
            ["version": Preferences.supportedVersion],
            ["version": Preferences.supportedVersion, "apps": ["unexpected"]]
        ]
        for root in roots {
            try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
            XCTAssertNil(Preferences(contentsOf: url))
        }
    }

    func testPreferencesLiveBesideTheDatabaseInItsGroupContainer() {
        XCTAssertEqual(
            Preferences.url(forDatabase: ShellNotificationStore.defaultURL),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"
            )
        )
    }

    func testAnEntryDecidesListingWithoutLookingForTheApp() throws {
        let other = UInt64(Int64.max) & ~(allowed | hidden)
        let preferences = try load([
            ["bundle-id": "allowed", "flags": allowed],
            ["bundle-id": "allowed-with-other-bits", "flags": allowed | other],
            ["bundle-id": "boolean", "flags": false],
            ["bundle-id": "string", "flags": String(hidden)],
            ["bundle-id": "negative", "flags": -Int64(hidden)],
            ["bundle-id": "fraction", "flags": Double(hidden) / 2],
            ["bundle-id": "missing"],
            ["bundle-id": "center-off", "flags": allowed | hidden],
            ["bundle-id": "center-off-with-other-bits", "flags": allowed | hidden | other],
            ["bundle-id": "not-allowed", "flags": other],
            ["bundle-id": "nothing-set", "flags": UInt64.zero]
        ])
        var lookups: [String] = []
        let isInstalled: (String) -> Bool = {
            lookups.append($0)
            return false
        }
        for bundle in ["allowed", "allowed-with-other-bits", "boolean", "string", "negative", "fraction", "missing"] {
            XCTAssertTrue(preferences.lists(bundle, isInstalled: isInstalled), bundle)
        }
        for bundle in ["center-off", "center-off-with-other-bits", "not-allowed", "nothing-set"] {
            XCTAssertFalse(preferences.lists(bundle, isInstalled: isInstalled), bundle)
        }
        XCTAssertEqual(lookups, [])
    }

    func testCaseVariantsOfOneBundleAreAmbiguousAndStayListed() throws {
        let entries: [[String: Any]] = [
            ["bundle-id": "com.example.MixedCase", "flags": hidden],
            ["bundle-id": "com.example.mixedcase", "flags": allowed],
            ["bundle-id": "COM.EXAMPLE.MIXEDCASE", "flags": hidden],
            ["bundle-id": "com.example.Hidden", "flags": hidden]
        ]
        for apps in [entries, Array(entries.reversed())] {
            let preferences = try load(apps)
            XCTAssertTrue(preferences.lists("com.example.mixedCASE", isInstalled: { _ in false }))
            XCTAssertFalse(preferences.lists("COM.EXAMPLE.HIDDEN", isInstalled: { _ in true }))
        }
    }

    func testSystemCenterSourcesAreNeverListed() throws {
        let prefix = Preferences.systemCenterPrefix
        let preferences = try load([["bundle-id": prefix.uppercased() + "com.example.Agent", "flags": allowed]])
        for bundle in [
            prefix + "com.example.agent", prefix.uppercased() + "com.example.Agent", prefix + "com.example.unknown"
        ] {
            XCTAssertFalse(preferences.lists(bundle, isInstalled: { _ in true }), bundle)
        }
    }

    func testAnAppWithoutAnEntryIsListedOnlyWhenInstalled() throws {
        let preferences = try load([])
        let installed = "com.example.Installed"
        XCTAssertTrue(preferences.lists(installed, isInstalled: { $0 == installed }))
        XCTAssertFalse(preferences.lists("com.example.Removed", isInstalled: { $0 == installed }))
        for prompt in [Preferences.permissionPromptSource, Preferences.permissionPromptSource.uppercased()] {
            XCTAssertTrue(preferences.lists(prompt, isInstalled: { _ in false }), prompt)
        }
    }

    private func load(_ apps: [[String: Any]]) throws -> ShellNotificationPreferences {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try notificationPreferences(apps).write(to: url)
        return try XCTUnwrap(Preferences(contentsOf: url))
    }
}
