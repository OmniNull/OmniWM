// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellNotificationPreferencesTests: XCTestCase {
    func testMissingMalformedAndUnknownPreferencesAreDistinctFromNoExclusions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(ShellNotificationPreferences.excludedBundles(at: url))
        let empty: [String: Any] = ["version": 1, "apps": []]
        try PropertyListSerialization.data(fromPropertyList: empty, format: .binary, options: 0).write(to: url)
        XCTAssertEqual(ShellNotificationPreferences.excludedBundles(at: url), [])
        try Data([1, 2, 3]).write(to: url)
        XCTAssertNil(ShellNotificationPreferences.excludedBundles(at: url))
        let roots: [[String: Any]] = [
            ["version": 2, "apps": [["bundle-id": "fixture", "flags": 0]]],
            ["version": true, "apps": [["bundle-id": "fixture", "flags": 0]]],
            ["version": 1],
            ["version": 1, "apps": ["unexpected"]]
        ]
        for root in roots {
            try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
            XCTAssertNil(ShellNotificationPreferences.excludedBundles(at: url))
        }
    }

    func testOnlyUnambiguousIntegerFlagsExcludeApps() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let root: [String: Any] = ["version": 1, "apps": [
            ["bundle-id": "center-off", "flags": (1 << 25) | 1],
            ["bundle-id": "all-off", "flags": 0],
            ["bundle-id": "center-on", "flags": 1 << 25],
            ["bundle-id": "banner-on-center-off", "flags": (1 << 25) | 9],
            ["bundle-id": "unknown-high-bit", "flags": (1 << 40) | (1 << 25)],
            ["bundle-id": "boolean", "flags": false],
            ["bundle-id": "string", "flags": "0"],
            ["bundle-id": "negative", "flags": -1],
            ["bundle-id": "fraction", "flags": 0.5],
            ["bundle-id": "missing"],
            ["bundle-id": "duplicate", "flags": 0],
            ["bundle-id": "duplicate", "flags": 1 << 25],
            ["bundle-id": "duplicate", "flags": 0]
        ]]
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
        XCTAssertEqual(
            ShellNotificationPreferences.excludedBundles(at: url),
            ["center-off", "all-off", "banner-on-center-off"]
        )
    }
}
