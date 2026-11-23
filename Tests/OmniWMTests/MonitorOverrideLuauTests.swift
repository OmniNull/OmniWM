// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class MonitorOverrideLuauTests: XCTestCase {
    private let overrides = [
        "monitorBarOverrides": "enabled = false",
        "monitorOrientationOverrides": "orientation = \"vertical\"",
        "monitorNiriOverrides": "visibleContainerCount = 2",
        "monitorDwindleOverrides": "defaultSplitRatio = 0.6",
        "monitorGapOverrides": "outerGapTop = 4.0"
    ]

    func testGeneratedDefaultsHaveNoOverrideRows() throws {
        let data = try SettingsLuauDocument.initialSource(.defaults())
        let tree = try SettingsLuauFixture.fields(in: data)
        for key in overrides.keys {
            if let field = tree[key] { XCTAssertEqual(field, .record([:]), key) }
        }
        let result = try SettingsLuauDocument(data)
        XCTAssertEqual(result.export, .defaults())
    }

    func testDocumentedOverridesCanBeWrittenAndCleared() throws {
        for (key, value) in overrides {
            let id = key == "monitorOrientationOverrides" ? "" : "id = '\(UUID().uuidString)', "
            let added = Data("return { \(key) = { { \(id)monitorName = 'Example display', \(value) } } }".utf8)
            let export = try SettingsLuauFixture.decode(added)
            let saved = try SettingsLuauDocument.initialSource(export)
            guard case let .list(rows) = try SettingsLuauFixture.fields(in: saved)[key] else {
                return XCTFail("Missing saved override: \(key)")
            }
            XCTAssertEqual(rows.count, 1, key)
            XCTAssertEqual(try SettingsLuauFixture.decode(saved), export, key)
            XCTAssertNotEqual(export, .defaults(), key)
            let cleared = try SettingsLuauFixture.editing(saved, to: .defaults())
            XCTAssertEqual(try SettingsLuauFixture.decode(cleared), .defaults(), key)
        }
    }

    func testExplicitEmptyOverridesUseDefaults() throws {
        let fields = overrides.mapValues { _ in SettingsLuauValue.list([]) }
        XCTAssertEqual(try SettingsLuauFixture.decode(SettingsLuauFixture.source(fields)), .defaults())
    }

    func testUnknownOverrideKeysRejectTheFile() {
        for key in overrides.keys {
            let source = Data("return { \(key) = { { monitorName = 'Example display', futureOverride = true } } }".utf8)
            XCTAssertThrowsError(try SettingsLuauFixture.decode(source)) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("\(key)[0].futureOverride"),
                    error.localizedDescription
                )
            }
        }
    }

    func testMalformedOverridesRejectTheFile() {
        for key in overrides.keys {
            for value in ["false", "3", "'invalid'", "{ 3 }", "{ { monitorName = 3 } }", "{ invalid = true }"] {
                let malformed = Data("return { \(key) = \(value) }".utf8)
                XCTAssertThrowsError(try SettingsLuauFixture.decode(malformed), "\(key) = \(value)")
            }
        }
    }
}
