// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ContiguousSectionsSettingsExportTests: XCTestCase {
    func testAllMovedFieldsRemainRequired() throws {
        let sections = [
            "borders": ["enabled", "width"],
            "borders.color": ["red", "green", "blue", "alpha"],
            "gestures": [
                "scrollEnabled", "scrollSensitivity", "scrollModifierKey",
                "fingerCount", "invertDirection", "trackpadScrollStyle",
                "workspaceSwipeEnabled", "workspaceSwipeFingerCount", "workspaceSwipeAxis"
            ],
            "statusBar": ["showWorkspaceName", "showAppNames", "useWorkspaceId"],
            "hiddenBar": ["enabled", "hiddenBundleIDs", "rehideIntervalSeconds"]
        ]
        for (section, keys) in sections {
            try SettingsLuauFixture.assertRequiredFields(keys, in: section)
        }
    }

    @MainActor
    func testStatusBarIconStaysShownWhenOmittedAndRoundTripsWhenHidden() throws {
        let source = String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
        let omitted = try removing(key: "showIcon", from: "statusBar", in: source)
        let decoded = try SettingsLuauFixture.decode(Data(omitted.utf8))
        XCTAssertNotEqual(decoded.statusBar.showIcon, false)
        let settings = StatusBarSettings()
        settings.showIcon = false
        settings.apply(decoded.statusBar)
        XCTAssertTrue(settings.showIcon)

        var hidden = SettingsExport.defaults()
        hidden.statusBar.showIcon = false
        XCTAssertEqual(
            try SettingsLuauFixture.decode(SettingsLuauDocument.initialSource(hidden)).statusBar.showIcon,
            false
        )
    }

    @MainActor
    func testStatusBarLayoutDefaultsOffForExistingFilesAndRoundTrips() throws {
        let source = String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
        let omitted = try removing(key: "showLayout", from: "statusBar", in: source)
        let decoded = try SettingsLuauFixture.decode(Data(omitted.utf8))
        let settings = StatusBarSettings()
        settings.showLayout = true
        settings.apply(decoded.statusBar)
        XCTAssertFalse(settings.showLayout)
        XCTAssertEqual(decoded.statusBar.showLayout, false)

        for enabled in [true, false] {
            settings.showLayout = enabled
            var export = SettingsExport.defaults()
            export.statusBar = settings.export()
            XCTAssertEqual(
                try SettingsLuauFixture.decode(SettingsLuauDocument.initialSource(export)).statusBar.showLayout,
                enabled
            )
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
