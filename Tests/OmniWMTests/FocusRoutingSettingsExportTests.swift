// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import TOML
import XCTest

final class FocusRoutingSettingsExportTests: XCTestCase {
    func testDefaultSectionsKeepCanonicalTableShapeAndValues() throws {
        let defaults = SettingsExport.defaults()
        let data = try SettingsTOMLCodec.encode(defaults)
        let tree = try TOMLDecoder().decode([String: TOMLNode].self, from: data)

        XCTAssertEqual(tree["focus"], .table([
            "followsMouse": .boolean(false),
            "raiseOnMouseFocus": .boolean(false),
            "lockModifier": .string("off"),
            "moveMouseToFocusedWindow": .boolean(false),
            "followsWindowToMonitor": .boolean(false),
            "crossesMonitorAtEdge": .boolean(false),
            "moveCrossesMonitorAtEdge": .boolean(false),
            "hoverFocusMaxScrollPercent": .integer(100)
        ]))
        XCTAssertEqual(tree["mouseWarp"], .table([
            "margin": .integer(1),
            "enabled": .boolean(true),
            "constrainToArrangement": .boolean(false)
        ]))
        XCTAssertEqual(tree["routing"], .table([
            "mode": .string("macOS"),
            "arrangements": .array([])
        ]))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data), defaults)
    }

    func testEverySectionFieldRemainsRequired() throws {
        let data = try SettingsTOMLCodec.encode(.defaults())
        let source = String(decoding: data, as: UTF8.self)
        let sections = [
            "focus": [
                "followsMouse", "raiseOnMouseFocus", "lockModifier", "moveMouseToFocusedWindow",
                "followsWindowToMonitor", "crossesMonitorAtEdge", "moveCrossesMonitorAtEdge"
            ],
            "mouseWarp": ["margin", "enabled", "constrainToArrangement"],
            "routing": ["mode", "arrangements"]
        ]
        for (section, keys) in sections {
            for key in keys {
                let incomplete = try removing(key: key, from: section, in: source)
                XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(incomplete.utf8))) { error in
                    guard case let DecodingError.keyNotFound(missingKey, context) = error else {
                        return XCTFail("Expected missing section field, got \(error)")
                    }
                    XCTAssertEqual(missingKey.stringValue, key)
                    XCTAssertEqual(context.codingPath.map(\.stringValue), [section])
                }
            }
        }
    }

    func testHoverFocusMaxScrollPercentIsOptionalAndDefaultsTo100() throws {
        let data = try SettingsTOMLCodec.encode(.defaults())
        let source = String(decoding: data, as: UTF8.self)
        let withoutKey = try removing(key: "hoverFocusMaxScrollPercent", from: "focus", in: source)

        let decoded = try SettingsTOMLCodec.decode(Data(withoutKey.utf8))

        XCTAssertEqual(decoded.focus.hoverFocusMaxScrollPercent, 100)
        XCTAssertEqual(decoded, .defaults())
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
