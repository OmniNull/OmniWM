// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class LayoutSectionsSettingsExportTests: XCTestCase {
    func testDefaultSectionsKeepCanonicalTableShapeAndValues() throws {
        let defaults = SettingsExport.defaults()
        let data = try SettingsLuauDocument.initialSource(defaults)
        let tree = try SettingsLuauFixture.fields(in: data)

        XCTAssertEqual(tree["gaps"], .record([
            "size": .integer(16),
            "fullscreenUsesOuterGaps": .boolean(false),
            "outer": .record(["left": .integer(0), "right": .integer(0), "top": .integer(0), "bottom": .integer(0)])
        ]))
        XCTAssertEqual(tree["niri"], .record([
            "visibleContainerCount": .integer(2),
            "infiniteLoop": .boolean(false),
            "centerFocusedColumn": .string("never"),
            "alwaysCenterSingleColumn": .boolean(false),
            "singleWindowFit": .string("fill"),
            "containerPrimarySpanPresets": .list([.number(1.0 / 3), .number(0.5), .number(2.0 / 3)]),
            "defaultContainerPrimarySpan": .number(0.5),
            "edgeGaps": .boolean(true),
            "resizeStepPercent": .integer(5),
            "moveWindowStacksIntoColumn": .boolean(true),
            "allowOverscroll": .boolean(false),
            "overscrollVisibleStripPercent": .integer(5),
            "shrinkToFit": .boolean(false),
            "edgePeekPercent": SettingsLuauFixture.number(BuiltInSettingsDefaults.niriEdgePeekPercent),
            "fitToVisibleContainerCount": .boolean(false),
            "keepExistingWindowWidth": .boolean(false),
            "keepSizeOnUnstack": .boolean(false),
            "keepSizesOnDisplayMove": .boolean(false),
            "keepSizesOnSettingsChange": .boolean(false),
            "keepStripEndsOnScreen": .boolean(false)
        ]))
        XCTAssertEqual(tree["dwindle"], .record([
            "smartSplit": .boolean(false),
            "defaultSplitRatio": .integer(1),
            "splitWidthMultiplier": .integer(1),
            "singleWindowFit": .string("fill"),
            "useGlobalGaps": .boolean(true),
            "moveToRootStable": .boolean(true)
        ]))
        XCTAssertEqual(try SettingsLuauFixture.decode(data), defaults)
    }

    func testNonoptionalSectionFieldsRemainRequired() throws {
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
            try SettingsLuauFixture.assertRequiredFields(keys, in: section)
        }
    }

    func testOptionalNiriSizingFieldsStayAbsentWithoutCodecDefaults() throws {
        var export = SettingsExport.defaults()
        export.niri.containerPrimarySpanPresets = nil
        export.niri.defaultContainerPrimarySpan = nil
        let data = try SettingsLuauDocument.initialSource(export)
        let tree = try SettingsLuauFixture.fields(in: data)
        let niriNode = try XCTUnwrap(tree["niri"])
        guard case let .record(niri) = niriNode else { return XCTFail("Expected niri table") }

        XCTAssertNil(niri["containerPrimarySpanPresets"])
        XCTAssertNil(niri["defaultContainerPrimarySpan"])
        XCTAssertEqual(try SettingsLuauFixture.decode(data), SettingsExport.defaults())
    }

    @MainActor
    func testResizeIncrementDefaultsWhenOmittedAndClampsInSettings() throws {
        let source = String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
        let omitted = try removing(key: "resizeStepPercent", from: "niri", in: source)
        let decoded = try SettingsLuauFixture.decode(Data(omitted.utf8))
        XCTAssertEqual(decoded.niri.resizeStepPercent, SettingsExport.Niri.defaults().resizeStepPercent)
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

        let decoded = try SettingsLuauFixture.decode(SettingsLuauDocument.initialSource(export))
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
        let source = String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
        for control in controls {
            XCTAssertEqual(SettingsExport.defaults().niri[keyPath: control.export], false, control.key)
            XCTAssertFalse(NiriSettings()[keyPath: control.setting], control.key)

            var export = SettingsExport.defaults()
            export.niri[keyPath: control.export] = true
            let encoded = try SettingsLuauDocument.initialSource(export)
            XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\(control.key) = true"), control.key)
            XCTAssertEqual(try SettingsLuauFixture.decode(encoded), export, control.key)
            XCTAssertNoThrow(try SettingsLuauFixture.decode(encoded), control.key)
            let settings = NiriSettings()
            settings.apply(export.niri, baseline: .defaults())
            XCTAssertTrue(settings[keyPath: control.setting], control.key)
            XCTAssertEqual(settings.export()[keyPath: control.export], true, control.key)

            let omitted = try removing(key: control.key, from: "niri", in: source)
            let result = try SettingsLuauDocument(Data(omitted.utf8))
            XCTAssertEqual(
                result.export.niri[keyPath: control.export],
                SettingsExport.Niri.defaults()[keyPath: control.export],
                control.key
            )
            settings.apply(result.export.niri, baseline: .defaults())
            XCTAssertFalse(settings[keyPath: control.setting], control.key)
        }
    }

    @MainActor
    func testDefaultSpanRoundTripsAsAutoAppWidthOrAClampedCustomSpan() throws {
        let source = String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
        let defaultLine = "defaultContainerPrimarySpan = 0.5,\n"
        XCTAssertTrue(source.contains(defaultLine))
        func loaded(_ line: String) throws -> NiriSettings {
            let settings = NiriSettings()
            let edited = source.replacingOccurrences(of: defaultLine, with: line)
            settings.apply(try SettingsLuauDocument(Data(edited.utf8)).export.niri, baseline: .defaults())
            return settings
        }

        let app = try loaded("defaultContainerPrimarySpan = \"app\",\n")
        XCTAssertTrue(app.opensNewWindowsAtAppWidth)
        XCTAssertNil(app.defaultContainerPrimarySpan)
        XCTAssertEqual(app.export().defaultContainerPrimarySpan, .app)
        var export = SettingsExport.defaults()
        export.niri.defaultContainerPrimarySpan = .app
        let encoded = try SettingsLuauDocument.initialSource(export)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("defaultContainerPrimarySpan = \"app\""))
        XCTAssertEqual(try SettingsLuauFixture.decode(encoded), export)

        let auto = try loaded("defaultContainerPrimarySpan = \"auto\",\n")
        XCTAssertFalse(auto.opensNewWindowsAtAppWidth)
        XCTAssertNil(auto.defaultContainerPrimarySpan)
        XCTAssertNil(auto.export().defaultContainerPrimarySpan)

        let custom = try loaded("defaultContainerPrimarySpan = 0.6,\n")
        XCTAssertFalse(custom.opensNewWindowsAtAppWidth)
        XCTAssertEqual(custom.defaultContainerPrimarySpan, 0.6)
        XCTAssertEqual(custom.export().defaultContainerPrimarySpan, .custom(0.6))

        let tooWide = try loaded("defaultContainerPrimarySpan = 1.5,\n")
        XCTAssertEqual(tooWide.defaultContainerPrimarySpan, NiriSettings.validatedDefaultContainerPrimarySpan(1.5))
    }

    @MainActor
    func testPeripheralVisionDefaultsToOffRoundTripsAndIsClampedFromZeroToTen() throws {
        XCTAssertEqual(BuiltInSettingsDefaults.niriEdgePeekPercent, 0)
        XCTAssertEqual(SettingsExport.defaults().niri.edgePeekPercent, BuiltInSettingsDefaults.niriEdgePeekPercent)
        XCTAssertEqual(NiriSettings().edgePeekPercent, BuiltInSettingsDefaults.niriEdgePeekPercent)
        var export = SettingsExport.defaults()
        export.niri.edgePeekPercent = 5
        let encoded = try SettingsLuauDocument.initialSource(export)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("edgePeekPercent = 5"))
        XCTAssertEqual(try SettingsLuauFixture.decode(encoded), export)

        let source = String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
        let omitted = try removing(key: "edgePeekPercent", from: "niri", in: source)
        let decoded = try SettingsLuauDocument(Data(omitted.utf8)).export
        XCTAssertEqual(decoded.niri.edgePeekPercent, BuiltInSettingsDefaults.niriEdgePeekPercent)
        let settings = NiriSettings()
        settings.apply(decoded.niri, baseline: .defaults())
        XCTAssertEqual(settings.edgePeekPercent, BuiltInSettingsDefaults.niriEdgePeekPercent)
        settings.edgePeekPercent = 40
        XCTAssertEqual(settings.edgePeekPercent, 10)
        settings.edgePeekPercent = -1
        XCTAssertEqual(settings.edgePeekPercent, 0)
    }

    @MainActor
    func testRemovedSwitchAndDropModifierAreRejected() throws {
        for key in ["macOSFusion", "macOSFusionModifier"] {
            let source = Data("return { niri = { \(key) = true } }".utf8)
            XCTAssertThrowsError(try SettingsLuauDocument(source)) { error in
                XCTAssertTrue(error.localizedDescription.contains("niri.\(key)"), error.localizedDescription)
            }
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
