// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
            "defaultContainerPrimarySpan": .float(0.5),
            "edgeGaps": .boolean(true),
            "resizeStepPercent": .integer(5),
            "moveWindowStacksIntoColumn": .boolean(true),
            "allowOverscroll": .boolean(false),
            "overscrollVisibleStripPercent": .integer(5),
            "shrinkToFit": .boolean(false),
            "macOSFusion": .boolean(false),
            "macOSFusionModifier": .string("option"),
            "edgePeek": .boolean(false),
            "edgePeekPercent": .float(3.0)
        ]))
        XCTAssertEqual(tree["dwindle"], .table([
            "smartSplit": .boolean(false),
            "defaultSplitRatio": .float(1),
            "splitWidthMultiplier": .float(1),
            "singleWindowFit": .string("fill"),
            "useGlobalGaps": .boolean(true),
            "moveToRootStable": .boolean(true)
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

    @MainActor
    func testResizeIncrementDefaultsWhenOmittedAndClampsInSettings() throws {
        let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let omitted = try removing(key: "resizeStepPercent", from: "niri", in: source)
        let decoded = try SettingsTOMLCodec.decode(Data(omitted.utf8))
        XCTAssertNil(decoded.niri.resizeStepPercent)
        let settings = NiriSettings()
        XCTAssertEqual(settings.resizeStepPercent, 5)
        settings.resizeStepPercent = 17
        settings.apply(decoded.niri, baseline: .defaults())
        XCTAssertEqual(settings.resizeStepPercent, 5)

        var savedValues: [Int] = []
        settings.onChange = { savedValues.append(settings.resizeStepPercent) }
        for (input, expected) in [(0, 1), (-7, 1), (101, 100), (1, 1), (100, 100), (7, 7)] {
            settings.resizeStepPercent = input
            XCTAssertEqual(settings.resizeStepPercent, expected)
            XCTAssertEqual(savedValues.last, expected)
        }
        XCTAssertEqual(savedValues.count, 6)
        settings.onChange = nil

        var exported = SettingsExport.Niri.defaults()
        exported.resizeStepPercent = -1
        settings.apply(exported, baseline: .defaults())
        XCTAssertEqual(settings.resizeStepPercent, 1)
    }

    @MainActor
    func testResizeIncrementRoundTripPreservesShortcutAssignments() throws {
        let settings = NiriSettings()
        settings.resizeStepPercent = 7
        var export = SettingsExport.defaults()
        export.niri = settings.export()
        let ids = ["ContainerPrimary", "WindowPrimary", "WindowSecondary"].flatMap { span in
            ["shrink", "grow"].map { "resize\(span)Span.\($0)" }
        }
        let shortcut = try XCTUnwrap(KeySymbolMapper.fromHumanReadable("Hyper+Minus"))
        for index in export.hotkeyBindings.indices where ids.contains(export.hotkeyBindings[index].id) {
            export.hotkeyBindings[index] = try XCTUnwrap(HotkeyBindingRegistry.makeBinding(
                id: export.hotkeyBindings[index].id,
                binding: shortcut
            ))
        }

        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        let restored = NiriSettings()
        restored.apply(decoded.niri, baseline: .defaults())
        XCTAssertEqual(restored.resizeStepPercent, 7)
        XCTAssertEqual(decoded.hotkeyBindings, export.hotkeyBindings)
        XCTAssertEqual(decoded.hotkeyBindings.filter { ids.contains($0.id) }.count, 6)
    }

    @MainActor
    func testMacOSFusionDefaultsOffRoundTripsAndLoadsWhenOmitted() throws {
        XCTAssertEqual(SettingsExport.defaults().niri.macOSFusion, false)
        XCTAssertFalse(NiriSettings().macOSFusion)
        for enabled in [false, true] {
            var export = SettingsExport.defaults()
            export.niri.macOSFusion = enabled
            let encoded = try SettingsTOMLCodec.encode(export)
            XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("macOSFusion = \(enabled)"))
            XCTAssertEqual(try SettingsTOMLCodec.decode(encoded), export)
            XCTAssertTrue(SettingsTOMLCodec.unknownKeyPaths(in: encoded).isEmpty)
        }

        let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let omitted = try removing(key: "macOSFusion", from: "niri", in: source)
        let result = try SettingsTOMLCodec.decodeForLoad(Data(omitted.utf8))
        XCTAssertNil(result.migration)
        XCTAssertEqual(result.export.niri.macOSFusion, false)

        let settings = NiriSettings()
        var enabled = SettingsExport.Niri.defaults()
        enabled.macOSFusion = true
        settings.apply(enabled, baseline: .defaults())
        XCTAssertTrue(settings.macOSFusion)
        XCTAssertEqual(settings.export().macOSFusion, true)
    }

    @MainActor
    func testEdgePeekDefaultsOffRoundTripsAndLoadsWhenOmitted() throws {
        XCTAssertEqual(SettingsExport.defaults().niri.edgePeek, false)
        XCTAssertFalse(NiriSettings().edgePeek)
        for enabled in [false, true] {
            var export = SettingsExport.defaults()
            export.niri.edgePeek = enabled
            let encoded = try SettingsTOMLCodec.encode(export)
            XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("edgePeek = \(enabled)"))
            XCTAssertEqual(try SettingsTOMLCodec.decode(encoded), export)
            XCTAssertTrue(SettingsTOMLCodec.unknownKeyPaths(in: encoded).isEmpty)
        }

        let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let omitted = try removing(key: "edgePeek", from: "niri", in: source)
        let result = try SettingsTOMLCodec.decodeForLoad(Data(omitted.utf8))
        XCTAssertNil(result.migration)
        XCTAssertEqual(result.export.niri.edgePeek, false)

        let settings = NiriSettings()
        var enabled = SettingsExport.Niri.defaults()
        enabled.edgePeek = true
        settings.apply(enabled, baseline: .defaults())
        XCTAssertTrue(settings.edgePeek)
        XCTAssertEqual(settings.export().edgePeek, true)
    }

    @MainActor
    func testEdgePeekPercentDefaultsToThreeRoundTripsAndIsClamped() throws {
        XCTAssertEqual(SettingsExport.defaults().niri.edgePeekPercent, 3.0)
        XCTAssertEqual(NiriSettings().edgePeekPercent, 3.0)
        var export = SettingsExport.defaults()
        export.niri.edgePeekPercent = 2.5
        let encoded = try SettingsTOMLCodec.encode(export)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("edgePeekPercent = 2.5"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(encoded), export)

        let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let omitted = try removing(key: "edgePeekPercent", from: "niri", in: source)
        let decoded = try SettingsTOMLCodec.decodeForLoad(Data(omitted.utf8)).export
        XCTAssertNil(decoded.niri.edgePeekPercent)
        let settings = NiriSettings()
        settings.apply(decoded.niri, baseline: .defaults())
        XCTAssertEqual(settings.edgePeekPercent, 3.0)
        settings.edgePeekPercent = 40
        XCTAssertEqual(settings.edgePeekPercent, 10)
        settings.edgePeekPercent = 0
        XCTAssertEqual(settings.edgePeekPercent, 1)
    }

    @MainActor
    func testMacOSFusionModifierDefaultsToOptionRoundTripsAndLoadsWhenOmitted() throws {
        XCTAssertEqual(SettingsExport.defaults().niri.macOSFusionModifier, .option)
        XCTAssertEqual(NiriSettings().macOSFusionModifier, .option)
        for key in [MouseMoveModifierKey.off, .control, .controlOptionCommand] {
            var export = SettingsExport.defaults()
            export.niri.macOSFusionModifier = key
            let encoded = try SettingsTOMLCodec.encode(export)
            XCTAssertTrue(String(decoding: encoded, as: UTF8.self)
                .contains("macOSFusionModifier = \"\(key.rawValue)\""))
            XCTAssertEqual(try SettingsTOMLCodec.decode(encoded), export)
            XCTAssertTrue(SettingsTOMLCodec.unknownKeyPaths(in: encoded).isEmpty)
        }

        let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let omitted = try removing(key: "macOSFusionModifier", from: "niri", in: source)
        let result = try SettingsTOMLCodec.decodeForLoad(Data(omitted.utf8))
        XCTAssertNil(result.migration)
        XCTAssertEqual(result.export.niri.macOSFusionModifier, .option)

        let settings = NiriSettings()
        var changed = SettingsExport.Niri.defaults()
        changed.macOSFusionModifier = .command
        settings.apply(changed, baseline: .defaults())
        XCTAssertEqual(settings.macOSFusionModifier, .command)
        XCTAssertEqual(settings.export().macOSFusionModifier, .command)
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
