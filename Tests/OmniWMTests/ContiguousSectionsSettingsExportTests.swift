// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ContiguousSectionsSettingsExportTests: XCTestCase {
    func testAllMovedFieldsRemainRequired() throws {
        let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let sections = [
            "borders": ["enabled", "width"],
            "borders.color": ["red", "green", "blue", "alpha"],
            "gestures": [
                "scrollEnabled", "scrollSensitivity", "scrollModifierKey", "mouseMoveModifierKey",
                "mouseResizeModifierKey", "fingerCount", "invertDirection", "trackpadScrollStyle",
                "workspaceSwipeEnabled", "workspaceSwipeFingerCount", "workspaceSwipeAxis"
            ],
            "statusBar": ["showWorkspaceName", "showAppNames", "useWorkspaceId"],
            "hiddenBar": ["enabled", "hiddenBundleIDs", "rehideIntervalSeconds"]
        ]
        for (section, keys) in sections {
            for key in keys {
                let incomplete = try removing(key: key, from: section, in: source)
                XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(incomplete.utf8))) { error in
                    guard case let DecodingError.keyNotFound(missingKey, context) = error else {
                        return XCTFail("Expected missing section field, got \(error)")
                    }
                    XCTAssertEqual(missingKey.stringValue, key)
                    XCTAssertEqual(context.codingPath.map(\.stringValue), section.components(separatedBy: "."))
                }
            }
        }
    }

    @MainActor
    func testStatusBarIconStaysShownWhenOmittedAndRoundTripsWhenHidden() throws {
        let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let omitted = try removing(key: "showIcon", from: "statusBar", in: source)
        let decoded = try SettingsTOMLCodec.decode(Data(omitted.utf8))
        XCTAssertNotEqual(decoded.statusBar.showIcon, false)
        let settings = StatusBarSettings()
        settings.showIcon = false
        settings.apply(decoded.statusBar)
        XCTAssertTrue(settings.showIcon)

        var hidden = SettingsExport.defaults()
        hidden.statusBar.showIcon = false
        XCTAssertEqual(try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(hidden)).statusBar.showIcon, false)
    }

    private func removing(key: String, from section: String, in source: String) throws -> String {
        var lines = source.components(separatedBy: "\n")
        let header = try XCTUnwrap(lines.firstIndex(of: "[\(section)]"))
        let following = lines.indices.dropFirst(header + 1)
        let sectionEnd = following.first { lines[$0].hasPrefix("[") } ?? lines.endIndex
        let field = try XCTUnwrap(((header + 1) ..< sectionEnd).first {
            lines[$0].hasPrefix("\(key) = ")
        })
        lines.remove(at: field)
        return lines.joined(separator: "\n")
    }
}
