// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import TOML
import XCTest

final class LayoutSectionsSettingsExportTests: XCTestCase {
    func testDefaultSectionsKeepCanonicalTableShapeAndValues() throws {
        let defaults = SettingsExport.defaults()
        let data = try SettingsTOMLCodec.encode(defaults)
        let tree = try TOMLDecoder().decode([String: TOMLNode].self, from: data)

        XCTAssertEqual(tree["gaps"], .table([
            "size": .float(16),
            "fullscreenUsesOuterGaps": .boolean(false),
            "outer": .table(["left": .float(0), "right": .float(0), "top": .float(0), "bottom": .float(0)])
        ]))
        XCTAssertEqual(tree["niri"], .table([
            "visibleContainerCount": .integer(2),
            "infiniteLoop": .boolean(false),
            "centerFocusedColumn": .string("never"),
            "alwaysCenterSingleColumn": .boolean(false),
            "singleWindowFit": .string("fill"),
            "containerPrimarySpanPresets": .array([.float(1.0 / 3), .float(0.5), .float(2.0 / 3)]),
            "defaultContainerPrimarySpan": .float(0.5)
        ]))
        XCTAssertEqual(tree["dwindle"], .table([
            "smartSplit": .boolean(false),
            "defaultSplitRatio": .float(1),
            "splitWidthMultiplier": .float(1),
            "singleWindowFit": .string("fill"),
            "useGlobalGaps": .boolean(true),
            "moveToRootStable": .boolean(true),
            "stackIncomingWindows": .boolean(false)
        ]))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data), defaults)
    }

    func testNonoptionalSectionFieldsRemainRequired() throws {
        let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let sections = [
            "gaps": ["size", "fullscreenUsesOuterGaps"],
            "gaps.outer": ["left", "right", "top", "bottom"],
            "niri": [
                "visibleContainerCount", "infiniteLoop", "centerFocusedColumn",
                "alwaysCenterSingleColumn", "singleWindowFit"
            ],
            "dwindle": [
                "smartSplit", "defaultSplitRatio", "splitWidthMultiplier",
                "singleWindowFit", "useGlobalGaps", "moveToRootStable"
            ]
        ]
        for (section, keys) in sections {
            for key in keys {
                let incomplete = try removing(key: key, from: section, in: source)
                XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(incomplete.utf8))) { error in
                    guard case let DecodingError.keyNotFound(missingKey, context) = error else {
                        return XCTFail("Expected missing layout field, got \(error)")
                    }
                    XCTAssertEqual(missingKey.stringValue, key)
                    XCTAssertEqual(context.codingPath.map(\.stringValue), section.components(separatedBy: "."))
                }
            }
        }
    }

    func testOptionalNiriSizingFieldsStayAbsentWithoutCodecDefaults() throws {
        var export = SettingsExport.defaults()
        export.niri.containerPrimarySpanPresets = nil
        export.niri.defaultContainerPrimarySpan = nil
        let data = try SettingsTOMLCodec.encode(export)
        let tree = try TOMLDecoder().decode([String: TOMLNode].self, from: data)
        let niriNode = try XCTUnwrap(tree["niri"])
        guard case let .table(niri) = niriNode else { return XCTFail("Expected niri table") }

        XCTAssertNil(niri["containerPrimarySpanPresets"])
        XCTAssertNil(niri["defaultContainerPrimarySpan"])
        XCTAssertEqual(try SettingsTOMLCodec.decode(data), export)
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
