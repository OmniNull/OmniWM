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
            "edgePeekPercent": .float(BuiltInSettingsDefaults.niriEdgePeekPercent),
            "fitToVisibleContainerCount": .boolean(false),
            "keepExistingWindowWidth": .boolean(false),
            "keepSizeOnUnstack": .boolean(false),
            "keepSizesOnDisplayMove": .boolean(false),
            "keepSizesOnSettingsChange": .boolean(false),
            "keepStripEndsOnScreen": .boolean(false)
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
    func testStripControlsDefaultOffRoundTripAndLoadWhenOmitted() throws {
        let controls: [(
            key: String,
            export: WritableKeyPath<SettingsExport.Niri, Bool?>,
            setting: ReferenceWritableKeyPath<NiriSettings, Bool>
        )] = [
            ("fitToVisibleContainerCount", \.fitToVisibleContainerCount, \.fitToVisibleContainerCount),
            ("keepExistingWindowWidth", \.keepExistingWindowWidth, \.keepExistingWindowWidth),
            ("keepSizeOnUnstack", \.keepSizeOnUnstack, \.keepSizeOnUnstack),
            ("keepSizesOnDisplayMove", \.keepSizesOnDisplayMove, \.keepSizesOnDisplayMove),
            ("keepSizesOnSettingsChange", \.keepSizesOnSettingsChange, \.keepSizesOnSettingsChange),
            ("keepStripEndsOnScreen", \.keepStripEndsOnScreen, \.keepStripEndsOnScreen)
        ]
        let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        for control in controls {
            XCTAssertEqual(SettingsExport.defaults().niri[keyPath: control.export], false, control.key)
            XCTAssertFalse(NiriSettings()[keyPath: control.setting], control.key)

            var export = SettingsExport.defaults()
            export.niri[keyPath: control.export] = true
            let encoded = try SettingsTOMLCodec.encode(export)
            XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\(control.key) = true"), control.key)
            XCTAssertEqual(try SettingsTOMLCodec.decode(encoded), export, control.key)
            XCTAssertTrue(SettingsTOMLCodec.unknownKeyPaths(in: encoded).isEmpty, control.key)

            let settings = NiriSettings()
            settings.apply(export.niri, baseline: .defaults())
            XCTAssertTrue(settings[keyPath: control.setting], control.key)
            XCTAssertEqual(settings.export()[keyPath: control.export], true, control.key)

            let omitted = try removing(key: control.key, from: "niri", in: source)
            let result = try SettingsTOMLCodec.decodeForLoad(Data(omitted.utf8))
            XCTAssertNil(result.migration, control.key)
            XCTAssertNil(result.export.niri[keyPath: control.export], control.key)
            settings.apply(result.export.niri, baseline: .defaults())
            XCTAssertFalse(settings[keyPath: control.setting], control.key)
        }
    }

    @MainActor
    func testDefaultSpanRoundTripsAsAutoAppWidthOrAClampedCustomSpan() throws {
        let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let defaultLine = "defaultContainerPrimarySpan = 0.5\n"
        XCTAssertTrue(source.contains(defaultLine))
        func loaded(_ line: String) throws -> NiriSettings {
            let settings = NiriSettings()
            let edited = source.replacingOccurrences(of: defaultLine, with: line)
            settings.apply(try SettingsTOMLCodec.decodeForLoad(Data(edited.utf8)).export.niri, baseline: .defaults())
            return settings
        }

        let app = try loaded("defaultContainerPrimarySpan = \"app\"\n")
        XCTAssertTrue(app.opensNewWindowsAtAppWidth)
        XCTAssertNil(app.defaultContainerPrimarySpan)
        XCTAssertEqual(app.export().defaultContainerPrimarySpan, .app)
        var export = SettingsExport.defaults()
        export.niri.defaultContainerPrimarySpan = .app
        let encoded = try SettingsTOMLCodec.encode(export)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("defaultContainerPrimarySpan = \"app\""))
        XCTAssertEqual(try SettingsTOMLCodec.decode(encoded), export)

        let auto = try loaded("")
        XCTAssertFalse(auto.opensNewWindowsAtAppWidth)
        XCTAssertNil(auto.defaultContainerPrimarySpan)
        XCTAssertNil(auto.export().defaultContainerPrimarySpan)

        let custom = try loaded("defaultContainerPrimarySpan = 0.6\n")
        XCTAssertFalse(custom.opensNewWindowsAtAppWidth)
        XCTAssertEqual(custom.defaultContainerPrimarySpan, 0.6)
        XCTAssertEqual(custom.export().defaultContainerPrimarySpan, .custom(0.6))

        let tooWide = try loaded("defaultContainerPrimarySpan = 1.5\n")
        XCTAssertEqual(tooWide.defaultContainerPrimarySpan, NiriSettings.validatedDefaultContainerPrimarySpan(1.5))
    }

    @MainActor
    func testPeripheralVisionDefaultsToOffRoundTripsAndIsClampedFromZeroToTen() throws {
        XCTAssertEqual(BuiltInSettingsDefaults.niriEdgePeekPercent, 0)
        XCTAssertEqual(SettingsExport.defaults().niri.edgePeekPercent, BuiltInSettingsDefaults.niriEdgePeekPercent)
        XCTAssertEqual(NiriSettings().edgePeekPercent, BuiltInSettingsDefaults.niriEdgePeekPercent)
        var export = SettingsExport.defaults()
        export.niri.edgePeekPercent = 5
        let encoded = try SettingsTOMLCodec.encode(export)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("edgePeekPercent = 5"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(encoded), export)

        let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let omitted = try removing(key: "edgePeekPercent", from: "niri", in: source)
        let decoded = try SettingsTOMLCodec.decodeForLoad(Data(omitted.utf8)).export
        XCTAssertNil(decoded.niri.edgePeekPercent)
        let settings = NiriSettings()
        settings.apply(decoded.niri, baseline: .defaults())
        XCTAssertEqual(settings.edgePeekPercent, BuiltInSettingsDefaults.niriEdgePeekPercent)
        settings.edgePeekPercent = 40
        XCTAssertEqual(settings.edgePeekPercent, 10)
        settings.edgePeekPercent = -1
        XCTAssertEqual(settings.edgePeekPercent, 0)
    }

    @MainActor
    func testASettingsFileThatStillHoldsTheRemovedSwitchAndDropModifierLoads() throws {
        let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let kept = "shrinkToFit = false\n"
        let removed = ["macOSFusion", "macOSFusionModifier"]
        let withOldKeys = source.replacingOccurrences(
            of: kept,
            with: kept + "\(removed[0]) = true\n\(removed[1]) = \"option\"\n"
        )
        XCTAssertNotEqual(withOldKeys, source)
        let result = try SettingsTOMLCodec.decodeForLoad(Data(withOldKeys.utf8))
        XCTAssertNil(result.migration)
        XCTAssertEqual(result.export, SettingsExport.defaults())
        XCTAssertEqual(
            Set(SettingsTOMLCodec.unknownKeyPaths(in: Data(withOldKeys.utf8))),
            Set(removed.map { "niri.\($0)" })
        )
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
