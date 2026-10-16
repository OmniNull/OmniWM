// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import TOML
import XCTest

final class MonitorOverrideTOMLTests: XCTestCase {
    private let overrides = [
        "monitorBarOverrides": "enabled = false",
        "monitorOrientationOverrides": "orientation = \"vertical\"",
        "monitorNiriOverrides": "visibleContainerCount = 2",
        "monitorDwindleOverrides": "defaultSplitRatio = 0.6",
        "monitorGapOverrides": "outerGapTop = 4.0"
    ]

    func testGeneratedDefaultsOmitEmptyOverridesAndLoadWithoutMigration() throws {
        let data = try SettingsTOMLCodec.encode(.defaults())
        let tree = try TOMLDecoder().decode([String: TOMLNode].self, from: data)
        for key in overrides.keys {
            XCTAssertNil(tree[key], key)
        }
        let result = try SettingsTOMLCodec.decodeForLoad(data)
        XCTAssertEqual(result.export, .defaults())
        XCTAssertNil(result.migration)
        XCTAssertNil(result.migratedData)
    }

    func testDocumentedTablesCanBeAddedAndRemovedFromGeneratedFile() throws {
        let defaults = try SettingsTOMLCodec.encode(.defaults())
        for (key, value) in overrides {
            let added = Data((String(decoding: defaults, as: UTF8.self) + entry(key: key, value: value)).utf8)
            let export = try SettingsTOMLCodec.decode(added)
            let saved = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: added)
            let tree = try TOMLDecoder().decode([String: TOMLNode].self, from: saved)
            guard case let .array(rows) = tree[key] else {
                return XCTFail("Missing saved override: \(key)")
            }
            XCTAssertEqual(rows.count, 1, key)
            XCTAssertEqual(try SettingsTOMLCodec.decode(saved), export, key)
            XCTAssertNotEqual(export, .defaults(), key)

            let removed = removingTable(key, from: String(decoding: saved, as: UTF8.self))
            let cleared = try SettingsTOMLCodec.decode(Data(removed.utf8))
            XCTAssertEqual(cleared, .defaults(), key)
            XCTAssertEqual(try SettingsTOMLCodec.encode(cleared), defaults, key)
        }
    }

    func testExplicitEmptyOverridesStayKnownAndDisappearOnSave() throws {
        let emptyKeys = overrides.keys.sorted().map { "\($0) = []\n" }.joined()
        let original = Data((emptyKeys + String(
            decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self
        )).utf8)
        XCTAssertEqual(try SettingsTOMLCodec.decode(original), .defaults())
        XCTAssertTrue(SettingsTOMLCodec.unknownKeyPaths(in: original).isEmpty)
        let saved = try SettingsTOMLCodec.encode(.defaults(), preservingUnknownKeysFrom: original)
        XCTAssertEqual(saved, try SettingsTOMLCodec.encode(.defaults()))
    }

    func testClearingOverridesPreservesUnrelatedExtensionsWithoutResurrectingRows() throws {
        let defaults = try SettingsTOMLCodec.encode(.defaults())
        for (key, value) in overrides {
            let original = Data((
                "futureEntries = []\nfutureSetting = \"keep\"\n"
                    + String(decoding: defaults, as: UTF8.self)
                    + entry(key: key, value: value + "\nfutureOverride = true")
            ).utf8)
            let kept = try SettingsTOMLCodec.encode(
                SettingsTOMLCodec.decode(original), preservingUnknownKeysFrom: original
            )
            XCTAssertTrue(SettingsTOMLCodec.unknownKeyPaths(in: kept).contains("\(key)[0].futureOverride"))
            let cleared = try SettingsTOMLCodec.encode(.defaults(), preservingUnknownKeysFrom: kept)
            let tree = try TOMLDecoder().decode([String: TOMLNode].self, from: cleared)
            XCTAssertNil(tree[key], key)
            XCTAssertEqual(tree["futureEntries"], .array([]))
            XCTAssertEqual(tree["futureSetting"], .string("keep"))
            XCTAssertEqual(try SettingsTOMLCodec.decode(cleared), .defaults(), key)
        }
    }

    func testMalformedOverridesStillRejectTheWholeFile() throws {
        let defaults = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        for key in overrides.keys {
            for value in ["false", "3", "\"invalid\"", "{}", "[3]", "[{ monitorName = 3 }]"] {
                let malformed = Data(("\(key) = \(value)\n" + defaults).utf8)
                XCTAssertThrowsError(try SettingsTOMLCodec.decode(malformed), "\(key) = \(value)")
            }
            let collision = Data(("\(key) = []\n" + defaults + entry(key: key, value: "")).utf8)
            XCTAssertThrowsError(try SettingsTOMLCodec.decode(collision), key)
            let malformedRow = Data((defaults + "\n[[\(key)]]\nmonitorName = 3\n").utf8)
            XCTAssertThrowsError(try SettingsTOMLCodec.decode(malformedRow), key)
        }
    }

    private func entry(key: String, value: String) -> String {
        let id = key == "monitorOrientationOverrides" ? "" : "id = \"0B54A3C1-6E1B-4D5B-9A64-2F0D8A11C001\"\n"
        return "\n[[\(key)]]\n" + id + """
        monitorDisplayUUID = "3EFD184C-D5D3-40EF-AF27-14C4222A467B"
        monitorName = "Example display"
        \(value)

        """
    }

    private func removingTable(_ key: String, from text: String) -> String {
        var removing = false
        return text.components(separatedBy: "\n").filter { line in
            if line.hasPrefix("[") {
                removing = line == "[[\(key)]]"
            }
            return !removing
        }.joined(separator: "\n")
    }
}
