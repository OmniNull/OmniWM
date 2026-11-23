// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class FocusRoutingSettingsExportTests: XCTestCase {
    func testDefaultSectionsKeepCanonicalTableShapeAndValues() throws {
        let defaults = SettingsExport.defaults()
        let data = try SettingsLuauDocument.initialSource(defaults)
        let tree = try SettingsLuauFixture.fields(in: data)

        XCTAssertEqual(tree["focus"], .record([
            "followsMouse": .boolean(false),
            "followsMouseOnlyFullyVisible": .boolean(false),
            "clickFocusWithoutScrolling": .boolean(false),
            "edgeNavigationEnabled": .boolean(true),
            "edgeNavigationInterval": .number(1.5),
            "raiseOnMouseFocus": .boolean(false),
            "lockModifier": .string("off"),
            "moveMouseToFocusedWindow": .boolean(false),
            "followsWindowToMonitor": .boolean(false),
            "crossesMonitorAtEdge": .boolean(false),
            "moveCrossesMonitorAtEdge": .boolean(false)
        ]))
        XCTAssertEqual(tree["mouseWarp"], .record([
            "margin": .integer(1),
            "enabled": .boolean(true),
            "constrainToArrangement": .boolean(false)
        ]))
        XCTAssertEqual(tree["routing"], .record([
            "mode": .string("macOS"),
            "arrangements": .record([:])
        ]))
        XCTAssertEqual(try SettingsLuauFixture.decode(data), defaults)
    }

    func testEdgeNavigationCanBeDisabledAndDefaultsOnForExistingConfigurations() throws {
        var export = SettingsExport.defaults()
        export.focus.edgeNavigationEnabled = false
        let data = try SettingsLuauDocument.initialSource(export)
        XCTAssertEqual(try SettingsLuauFixture.decode(data), export)

        let source = String(decoding: data, as: UTF8.self)
        let missing = try removing(key: "edgeNavigationEnabled", from: "focus", in: source)
        let result = try SettingsLuauDocument(Data(missing.utf8))
        XCTAssertTrue(result.export.focus.edgeNavigationEnabled)
    }

    func testEveryEdgeNavigationIntervalRoundTrips() throws {
        var export = SettingsExport.defaults()
        for interval in stride(from: 0.25, through: 2.0, by: 0.25) {
            export.focus.edgeNavigationInterval = interval
            let data = try SettingsLuauDocument.initialSource(export)
            let result = try SettingsLuauDocument(data)
            XCTAssertEqual(result.export, export)

            XCTAssertNoThrow(try SettingsLuauFixture.decode(data))
        }
    }

    func testFullyVisibleHoverSettingRoundTripsAndDefaultsForExistingConfigurations() throws {
        var export = SettingsExport.defaults()
        export.focus.followsMouseOnlyFullyVisible = true
        let data = try SettingsLuauDocument.initialSource(export)
        XCTAssertEqual(try SettingsLuauFixture.decode(data), export)
        let source = String(decoding: data, as: UTF8.self)
        let missing = try removing(key: "followsMouseOnlyFullyVisible", from: "focus", in: source)
        let result = try SettingsLuauDocument(Data(missing.utf8))
        XCTAssertFalse(result.export.focus.followsMouseOnlyFullyVisible)

        let malformed = source.replacingOccurrences(
            of: "followsMouseOnlyFullyVisible = true", with: "followsMouseOnlyFullyVisible = \"true\""
        )
        XCTAssertThrowsError(try SettingsLuauFixture.decode(Data(malformed.utf8)))
    }

    func testClickFocusWithoutScrollingRoundTripsAndDefaultsForExistingConfigurations() throws {
        var export = SettingsExport.defaults()
        export.focus.clickFocusWithoutScrolling = true
        let data = try SettingsLuauDocument.initialSource(export)
        XCTAssertEqual(try SettingsLuauFixture.decode(data), export)
        let source = String(decoding: data, as: UTF8.self)
        let missing = try removing(key: "clickFocusWithoutScrolling", from: "focus", in: source)
        let result = try SettingsLuauDocument(Data(missing.utf8))
        XCTAssertFalse(result.export.focus.clickFocusWithoutScrolling)

        let malformed = source.replacingOccurrences(
            of: "clickFocusWithoutScrolling = true", with: "clickFocusWithoutScrolling = \"true\""
        )
        XCTAssertThrowsError(try SettingsLuauFixture.decode(Data(malformed.utf8)))
    }

    func testEdgeNavigationIntervalNormalizesAtLuauBoundary() throws {
        let source = String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
        for (literal, expected) in [
            ("0", 0.25), ("-1.0", 0.25), ("0.374", 0.25), ("0.375", 0.5),
            ("1.375", 1.5), ("3.0", 2.0)
        ] {
            let data = Data(source.replacingOccurrences(
                of: "edgeNavigationInterval = 1.5",
                with: "edgeNavigationInterval = \(literal)"
            ).utf8)
            XCTAssertEqual(try SettingsLuauFixture.decode(data).focus.edgeNavigationInterval, expected, literal)
        }
        var export = SettingsExport.defaults()
        for (value, expected) in [(Double.nan, 1.5), (.infinity, 1.5), (-2.0, 0.25), (1.375, 1.5), (4.0, 2.0)] {
            export.focus.edgeNavigationInterval = value
            let data = try SettingsLuauDocument.initialSource(export)
            XCTAssertEqual(try SettingsLuauFixture.decode(data).focus.edgeNavigationInterval, expected)
        }
    }

    func testOmittedEdgeNavigationIntervalUsesDefaultAndMalformedValueFails() throws {
        let source = String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
        let missing = try removing(key: "edgeNavigationInterval", from: "focus", in: source)
        let result = try SettingsLuauDocument(Data(missing.utf8))
        XCTAssertEqual(result.export.focus.edgeNavigationInterval, 1.5)

        let malformed = source.replacingOccurrences(
            of: "edgeNavigationInterval = 1.5",
            with: "edgeNavigationInterval = \"1.5\""
        )
        XCTAssertThrowsError(try SettingsLuauFixture.decode(Data(malformed.utf8))) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("focus.edgeNavigationInterval"),
                error.localizedDescription
            )
        }
    }

    func testExistingSectionFieldsRemainRequired() throws {
        let sections = [
            "focus": [
                "followsMouse", "raiseOnMouseFocus", "lockModifier", "moveMouseToFocusedWindow",
                "followsWindowToMonitor", "crossesMonitorAtEdge", "moveCrossesMonitorAtEdge"
            ],
            "mouseWarp": ["margin", "enabled", "constrainToArrangement"],
            "routing": ["mode", "arrangements"]
        ]
        for (section, keys) in sections {
            try SettingsLuauFixture.assertRequiredFields(keys, in: section)
        }
    }

    private func removing(key: String, from section: String, in source: String) throws -> String {
        var tree = SettingsLuauValue.record(try SettingsLuauFixture.fields(in: Data(source.utf8)))
        let parts = section.split(separator: ".").map(String.init) + [key]
        XCTAssertNotNil(parts.reduce(Optional(tree)) { $0?[$1] })
        tree.set(nil, at: parts[...])
        return "return " + tree.literal()
    }
}
