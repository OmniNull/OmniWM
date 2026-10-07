// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
@testable import OmniWM
import XCTest

final class SettingsTOMLCodecTests: XCTestCase {
    func testScrollModifierChoicesRoundTripWithOptionShiftDefault() throws {
        var export = SettingsExport.defaults()
        XCTAssertEqual(export.gestures.scrollModifierKey, .optionShift)
        for modifier in ScrollModifierKey.allCases {
            export.gestures.scrollModifierKey = modifier
            let data = try SettingsTOMLCodec.encode(export)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(
                "scrollModifierKey = \"\(modifier.rawValue)\""
            ))
            let result = try SettingsTOMLCodec.decodeForLoad(data)
            XCTAssertEqual(result.export, export)
            XCTAssertNil(result.migration)
            XCTAssertNil(result.migratedData)
        }
    }

    func testAnimationSpeedDefaultsAndRoundTrips() throws {
        var export = SettingsExport.defaults()
        XCTAssertEqual(export.animationSpeed, 1)
        for speed in [0.25, 1, 1.75, 2, 4] {
            export.animationSpeed = speed
            let data = try SettingsTOMLCodec.encode(export)
            XCTAssertEqual(try SettingsTOMLCodec.decode(data), export)
            XCTAssertFalse(SettingsTOMLCodec.unknownKeyPaths(in: data).contains("general.animationSpeed"))
        }
    }

    func testOmittedAnimationSpeedUsesDefaultWithoutMigration() throws {
        let data = try canonicalDefaultLines { lines in
            let index = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("animationSpeed = ") })
            lines.remove(at: index)
        }
        let result = try SettingsTOMLCodec.decodeForLoad(data)
        XCTAssertEqual(result.export.animationSpeed, 1)
        XCTAssertNil(result.migration)
        XCTAssertNil(result.migratedData)
    }

    func testAnimationSpeedNormalizesOutOfRangeAndNonfiniteTOML() throws {
        for (literal, expected) in [("0", 0.25), ("-2.0", 0.25), ("10.0", 4), ("nan", 1), ("inf", 1)] {
            let data = try canonicalDefaultLines { lines in
                let index = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("animationSpeed = ") })
                lines[index] = "animationSpeed = \(literal)"
            }
            XCTAssertEqual(try SettingsTOMLCodec.decode(data).animationSpeed, expected)
        }
    }

    func testTabRailAppIconsDefaultsAndRoundTrips() throws {
        var export = SettingsExport.defaults()
        XCTAssertFalse(export.tabRailAppIcons)

        for enabled in [false, true] {
            export.tabRailAppIcons = enabled
            let data = try SettingsTOMLCodec.encode(export)
            let text = String(decoding: data, as: UTF8.self)
            let appearanceSection = try XCTUnwrap(text.components(separatedBy: "[appearance]\n").last)
                .components(separatedBy: "\n[").first

            XCTAssertTrue(try XCTUnwrap(appearanceSection).contains("tabRailAppIcons = \(enabled)"))
            XCTAssertEqual(try SettingsTOMLCodec.decode(data), export)
            XCTAssertFalse(SettingsTOMLCodec.unknownKeyPaths(in: data).contains("appearance.tabRailAppIcons"))
        }
    }

    func testMissingTabRailAppIconsDefaultsToCompactWithoutMigration() throws {
        let withoutKey = try canonicalDefaultLines { lines in
            let index = try XCTUnwrap(lines.firstIndex(of: "tabRailAppIcons = false"))
            lines.remove(at: index)
        }

        let result = try SettingsTOMLCodec.decodeForLoad(withoutKey)

        XCTAssertFalse(result.export.tabRailAppIcons)
        XCTAssertNil(result.migration)
        XCTAssertNil(result.migratedData)
    }

    func testDefaultTOMLOmitsUnassignableHotkeyActions() throws {
        let toml = String(
            decoding: try SettingsTOMLCodec.encode(.defaults()),
            as: UTF8.self
        )

        for id in ["consumeOrExpelWindowLeft", "consumeOrExpelWindowRight"] {
            XCTAssertFalse(toml.contains(#"id = "\#(id)""#))
        }
    }

    func testTOMLRejectsUnassignableHotkeyActions() throws {
        for id in ["consumeOrExpelWindowLeft", "consumeOrExpelWindowRight"] {
            let source = Data(
                (String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self) + """

                [[hotkeys]]
                binding = "Option+H"
                id = "\(id)"
                """).utf8
            )

            XCTAssertThrowsError(try SettingsTOMLCodec.decode(source)) { error in
                XCTAssertEqual(
                    error as? HotkeyBindingResolutionError,
                    .unassignableActionID(id)
                )
                XCTAssertEqual(
                    error.localizedDescription,
                    "hotkeys: \(id) cannot be assigned as a hotkey."
                )
            }
        }
    }

    func testTOMLRejectsFileMissingAKnownHotkeyAction() throws {
        let firstID = try XCTUnwrap(HotkeyBindingRegistry.defaults().first?.id)
        let withoutEntry = try canonicalDefaultLines { lines in
            let idIndex = try XCTUnwrap(lines.firstIndex(of: #"id = "\#(firstID)""#))
            XCTAssertEqual(lines[idIndex - 2], "[[hotkeys]]")
            lines.removeSubrange((idIndex - 2) ... idIndex)
        }

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(withoutEntry)) { error in
            XCTAssertEqual(error as? HotkeyBindingResolutionError, .missingActionID(firstID))
        }
    }

    func testTOMLRejectsDuplicateHotkeyAction() throws {
        let firstID = try XCTUnwrap(HotkeyBindingRegistry.defaults().first?.id)
        let duplicated = try canonicalDefaultLines { lines in
            let idIndex = try XCTUnwrap(lines.firstIndex(of: #"id = "\#(firstID)""#))
            XCTAssertEqual(lines[idIndex - 2], "[[hotkeys]]")
            lines.insert(contentsOf: lines[(idIndex - 2) ... idIndex], at: idIndex + 1)
        }

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(duplicated)) { error in
            XCTAssertEqual(error as? HotkeyBindingResolutionError, .duplicateActionID(firstID))
        }
    }

    func testTOMLRejectsMissingRequiredKey() throws {
        let withoutKey = try canonicalDefaultLines { lines in
            let index = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("followsMouse = ") })
            lines.remove(at: index)
        }

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(withoutKey)) { error in
            guard case let DecodingError.keyNotFound(key, context) = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "followsMouse")
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["focus"])
        }
    }

    func testTOMLRejectsMissingRaiseOnMouseFocus() throws {
        let withoutKey = try canonicalDefaultLines { lines in
            let index = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("raiseOnMouseFocus = ") })
            lines.remove(at: index)
        }

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(withoutKey)) { error in
            guard case let DecodingError.keyNotFound(key, context) = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "raiseOnMouseFocus")
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["focus"])
        }
    }

    func testRaiseOnMouseFocusDefaultsAndRoundTrips() throws {
        var export = SettingsExport.defaults()

        XCTAssertFalse(export.focus.raiseOnMouseFocus)
        XCTAssertTrue(
            String(decoding: try SettingsTOMLCodec.encode(export), as: UTF8.self)
                .contains("raiseOnMouseFocus = false")
        )

        export.focus.raiseOnMouseFocus = true
        let data = try SettingsTOMLCodec.encode(export)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("raiseOnMouseFocus = true"))
        XCTAssertTrue(try SettingsTOMLCodec.decode(data).focus.raiseOnMouseFocus)
    }

    func testTOMLRejectsMissingFullscreenOuterGapPolicy() throws {
        let withoutKey = try canonicalDefaultLines { lines in
            let index = try XCTUnwrap(lines.firstIndex(of: "fullscreenUsesOuterGaps = false"))
            lines.remove(at: index)
        }

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(withoutKey)) { error in
            guard case let DecodingError.keyNotFound(key, context) = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "fullscreenUsesOuterGaps")
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["gaps"])
        }
    }

    func testTOMLRejectsCorruptSystemHyperTrigger() throws {
        let corrupt = try canonicalDefaultLines { lines in
            let index = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("systemHyperTrigger = ") })
            lines[index] = #"systemHyperTrigger = "NotAKey""#
        }

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(corrupt)) { error in
            guard case let DecodingError.dataCorrupted(context) = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["general", "systemHyperTrigger"])
        }
    }

    func testTOMLRejectsCorruptHyperKeyModifiers() throws {
        let corrupt = try canonicalDefaultLines { lines in
            let index = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("hyperKeyModifiers = ") })
            lines[index] = #"hyperKeyModifiers = "Control""#
        }

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(corrupt)) { error in
            guard case let DecodingError.dataCorrupted(context) = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["general", "hyperKeyModifiers"])
        }
    }

    func testHotkeyResolverRejectsUnknownMissingAndDuplicateActionIDs() throws {
        let defaults = HotkeyBindingRegistry.defaults()
        let complete = defaults.map { PersistedHotkeyBinding(id: $0.id, trigger: $0.binding) }
        XCTAssertEqual(try HotkeyBindingRegistry.resolve(complete).count, defaults.count)

        let withUnknown = complete + [PersistedHotkeyBinding(id: "retired.action", trigger: .unassigned)]
        XCTAssertThrowsError(try HotkeyBindingRegistry.resolve(withUnknown)) { error in
            XCTAssertEqual(error as? HotkeyBindingResolutionError, .unknownActionID("retired.action"))
            XCTAssertEqual(
                error.localizedDescription,
                "hotkeys: retired.action is not an action in this build."
            )
        }

        for id in ["consumeOrExpelWindowLeft", "consumeOrExpelWindowRight"] {
            let withUnassignable = complete + [PersistedHotkeyBinding(id: id, trigger: .unassigned)]
            XCTAssertThrowsError(try HotkeyBindingRegistry.resolve(withUnassignable)) { error in
                XCTAssertEqual(error as? HotkeyBindingResolutionError, .unassignableActionID(id))
                XCTAssertEqual(
                    error.localizedDescription,
                    "hotkeys: \(id) cannot be assigned as a hotkey."
                )
            }
        }

        let firstID = try XCTUnwrap(defaults.first?.id)
        XCTAssertThrowsError(try HotkeyBindingRegistry.resolve(Array(complete.dropFirst()))) { error in
            XCTAssertEqual(error as? HotkeyBindingResolutionError, .missingActionID(firstID))
        }

        let withDuplicate = try complete + [XCTUnwrap(complete.first)]
        XCTAssertThrowsError(try HotkeyBindingRegistry.resolve(withDuplicate)) { error in
            XCTAssertEqual(error as? HotkeyBindingResolutionError, .duplicateActionID(firstID))
        }
    }

    @MainActor
    func testLoadFailureReportsRejectedHotkeyActionsPrecisely() throws {
        let cases = [
            ("retired.action", "hotkeys: retired.action is not an action in this build."),
            (
                "consumeOrExpelWindowLeft",
                "hotkeys: consumeOrExpelWindowLeft cannot be assigned as a hotkey."
            )
        ]

        for (id, expectedMessage) in cases {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("OmniWMHotkeyReport-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self) + """

            [[hotkeys]]
            binding = "Option+H"
            id = "\(id)"
            """
            try Data(source.utf8).write(to: directory.appendingPathComponent("settings.toml"))

            LogErrorTap.shared.reset()
            let persistence = SettingsFilePersistence(
                directory: directory,
                startWatching: false,
                deferSaves: false
            )
            _ = persistence.load()

            XCTAssertTrue(LogErrorTap.shared.dump().contains(expectedMessage))
        }
    }

    private func canonicalDefaultLines(_ mutate: (inout [String]) throws -> Void) throws -> Data {
        let canonical = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        var lines = canonical.components(separatedBy: "\n")
        let original = lines
        try mutate(&lines)
        XCTAssertNotEqual(lines, original)
        return Data(lines.joined(separator: "\n").utf8)
    }

    func testFullscreenGapPolicyAndMonitorOverridesRoundTrip() throws {
        XCTAssertFalse(SettingsExport.defaults().gaps.fullscreenUsesOuterGaps)
        var export = SettingsExport.defaults()
        export.gaps.fullscreenUsesOuterGaps = true
        export.monitorGapSettings = [
            MonitorGapSettings(
                monitorName: "Built-in",
                monitorDisplayId: 7,
                innerGap: 6,
                outerGapTop: 20,
                fullscreenUsesOuterGaps: false
            )
        ]

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertTrue(decoded.gaps.fullscreenUsesOuterGaps)
        XCTAssertEqual(decoded.monitorGapSettings, export.monitorGapSettings)
        let toml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(toml.contains("innerGap = 6.0"))
        XCTAssertTrue(toml.contains("fullscreenUsesOuterGaps = true"))
        XCTAssertTrue(toml.contains("fullscreenUsesOuterGaps = false"))
    }

    func testPreservingEncodeKeepsUnknownKeysInsideKnownTables() throws {
        let previous = try defaultsWithReplacements(
            ("[general]\n", "[general]\nfutureSetting = \"keep-me\"\n"),
            ("[niri]\n", "[niri]\nfutureNiriSetting = true\n")
        )

        var export = try SettingsTOMLCodec.decode(previous)
        export.gaps.size = 24

        let rewritten = String(
            decoding: try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous),
            as: UTF8.self
        )

        XCTAssertTrue(rewritten.contains("futureSetting = \"keep-me\""))
        XCTAssertTrue(rewritten.contains("futureNiriSetting = true"))
        XCTAssertTrue(rewritten.contains("size = 24.0"))
    }

    func testPreservingEncodeUsesCanonicalDataOnlyWhenPreviousDataIsAbsent() throws {
        let export = SettingsExport.defaults()

        let rewritten = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: nil)

        XCTAssertEqual(rewritten, try SettingsTOMLCodec.encode(export))
    }

    func testPreservingEncodeRejectsEmptyPreviousData() {
        XCTAssertThrowsError(
            try SettingsTOMLCodec.encode(.defaults(), preservingUnknownKeysFrom: Data())
        ) { error in
            XCTAssertEqual(error as? SettingsTOMLCodecError, .cannotSafelyPreservePreviousData)
        }
    }

    func testPreservingEncodeRejectsMalformedPreviousData() {
        XCTAssertThrowsError(
            try SettingsTOMLCodec.encode(
                .defaults(),
                preservingUnknownKeysFrom: Data("[general\ninvalid".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? SettingsTOMLCodecError, .cannotSafelyPreservePreviousData)
        }
    }

    func testPreservingEncodeKeepsUnknownExtensionTables() throws {
        let previous = try defaultsWithSuffix(
            """

            [future]
            topValue = "top"

            [future.nested]
            flag = true
            """
        )

        var export = try SettingsTOMLCodec.decode(previous)
        export.gaps.size = 24

        let rewritten = String(
            decoding: try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous),
            as: UTF8.self
        )

        XCTAssertTrue(rewritten.contains("[future]"))
        XCTAssertTrue(rewritten.contains("topValue = \"top\""))
        XCTAssertTrue(rewritten.contains("[future.nested]"))
        XCTAssertTrue(rewritten.contains("flag = true"))
        XCTAssertTrue(rewritten.contains("size = 24.0"))
    }

    func testPreservingEncodeKeepsUnknownDateTimeTypes() throws {
        let previous = try defaultsWithSuffix(
            """

            [futureTimeTypes]
            futureDate = 2026-06-15
            futureLocalDateTime = 2026-06-15T12:30:00
            futureOffset = 2026-06-15T12:30:00-04:00
            futureTime = 12:30:00
            """
        )

        var export = try SettingsTOMLCodec.decode(previous)
        export.gaps.size = 24

        let rewritten = String(
            decoding: try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous),
            as: UTF8.self
        )

        XCTAssertTrue(rewritten.contains("futureDate = 2026-06-15"))
        XCTAssertTrue(rewritten.contains("futureLocalDateTime = 2026-06-15T12:30:00"))
        XCTAssertTrue(rewritten.contains("futureTime = 12:30:00"))

        let actualValue = try XCTUnwrap(tomlValue(for: "futureOffset", in: rewritten))
        let actual = try XCTUnwrap(parseOffsetDateTime(actualValue))
        let expected = try XCTUnwrap(parseOffsetDateTime("2026-06-15T12:30:00-04:00"))
        XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testPreservingEncodeDoesNotResurrectClearedKnownOptionals() throws {
        let previous = try SettingsTOMLCodec.encode(.defaults())

        var export = try SettingsTOMLCodec.decode(previous)
        export.quakeTerminal.opacity = nil

        let rewrittenData = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous)
        let rewritten = String(decoding: rewrittenData, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(rewrittenData)

        XCTAssertFalse(rewritten.contains("opacity = 1.0"))
        XCTAssertNil(decoded.quakeTerminal.opacity)
    }

    func testMonitorRankingRoundTripsInOrderAndTableIsOmittedWhenEmpty() throws {
        let defaults = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        XCTAssertFalse(defaults.contains("[monitors]"))
        XCTAssertFalse(defaults.contains("ranking"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(defaults.utf8)).monitorRanking, [])

        var export = SettingsExport.defaults()
        export.monitorRanking = [
            OutputId(displayUUID: "22222222-2222-2222-2222-222222222222", name: "DELL U3423WE"),
            OutputId(displayId: 7, name: "LG HDR 4K"),
            OutputId(name: "Built-in Retina Display")
        ]

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(toml.contains("[[monitors.ranking]]"), toml)
        XCTAssertTrue(toml.contains("displayUUID = \"22222222-2222-2222-2222-222222222222\""), toml)

        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertEqual(decoded.monitorRanking.map(\.name), ["DELL U3423WE", "LG HDR 4K", "Built-in Retina Display"])
        XCTAssertEqual(decoded.monitorRanking[0].displayUUID, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(decoded.monitorRanking[1].displayId, 7)
        XCTAssertNil(decoded.monitorRanking[2].displayUUID)
        XCTAssertNil(decoded.monitorRanking[2].displayId)
    }

    @MainActor
    func testSavePathPreservesUnknownKeys() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSettingsCodecTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previous = try defaultsWithReplacements(
            ("[general]\n", "[general]\nfutureSetting = \"keep-me\"\n")
        )
        let fileURL = directory.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
        try previous.write(to: fileURL, options: .atomic)

        let persistence = SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false)
        var export = persistence.load()
        export.gaps.size = 24

        try persistence.saveImmediately(export)

        let rewritten = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(rewritten.contains("futureSetting = \"keep-me\""))
        XCTAssertTrue(rewritten.contains("size = 24.0"))
    }

    func testPreservingEncodeKeepsCanonicalBytesWhenNoUnknownKeysExist() throws {
        let export = SettingsExport.defaults()
        let canonicalData = try SettingsTOMLCodec.encode(export)

        let rewritten = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: canonicalData)

        XCTAssertEqual(rewritten, canonicalData)
    }

    func testTrackpadScrollStyleRoundTrips() throws {
        XCTAssertEqual(SettingsExport.defaults().gestures.trackpadScrollStyle, .snap)

        var export = SettingsExport.defaults()
        export.gestures.trackpadScrollStyle = .momentum
        let data = try SettingsTOMLCodec.encode(export)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("trackpadScrollStyle = \"momentum\""))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).gestures.trackpadScrollStyle, .momentum)
    }

    func testMouseMoveModifierRoundTrips() throws {
        XCTAssertEqual(SettingsExport.defaults().gestures.mouseMoveModifierKey, .option)
        XCTAssertTrue(
            String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
                .contains("mouseMoveModifierKey = \"option\"")
        )

        for modifier in [MouseMoveModifierKey.off, .controlOption] {
            var export = SettingsExport.defaults()
            export.gestures.mouseMoveModifierKey = modifier
            let data = try SettingsTOMLCodec.encode(export)

            XCTAssertEqual(try SettingsTOMLCodec.decode(data).gestures.mouseMoveModifierKey, modifier)
        }
    }

    func testUnsupportedMouseMoveModifierRejectsDecode() throws {
        let data = try defaultsWithReplacements(
            ("mouseMoveModifierKey = \"option\"\n", "mouseMoveModifierKey = \"shift\"\n")
        )

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(data)) { error in
            XCTAssertTrue(SettingsTOMLCodec.diagnosticDescription(for: error).contains("gestures.mouseMoveModifierKey"))
        }
    }

    @MainActor
    func testMouseMoveModifierStoreMappingRoundTrips() {
        let source = makeSettingsStore()
        source.gestures.mouseMoveModifierKey = .controlCommand
        let destination = makeSettingsStore()

        destination.applyExport(source.toExport())

        XCTAssertEqual(destination.gestures.mouseMoveModifierKey, .controlCommand)
        XCTAssertEqual(destination.toExport().gestures.mouseMoveModifierKey, .controlCommand)
    }

    @MainActor
    func testRaiseOnMouseFocusStoreMappingSurvivesDisabledFocusFollowsMouse() {
        let source = makeSettingsStore()
        source.focus.followsMouse = false
        source.focus.raiseOnMouseFocus = true
        let destination = makeSettingsStore()

        destination.applyExport(source.toExport())

        XCTAssertFalse(destination.focus.followsMouse)
        XCTAssertTrue(destination.focus.raiseOnMouseFocus)
        XCTAssertTrue(destination.toExport().focus.raiseOnMouseFocus)
    }

    func testMalformedMouseMoveModifierTypeRejectsDecode() throws {
        let malformed = try defaultsWithReplacements(
            ("mouseMoveModifierKey = \"option\"\n", "mouseMoveModifierKey = 3\n")
        )

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(malformed))
    }

    func testOverviewGestureSettingsRoundTripAndExistingConfigDefaults() throws {
        var export = SettingsExport.defaults()
        export.gestures.overviewGestureEnabled = true
        export.gestures.overviewGestureFingerCount = .three
        let encoded = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(encoded)
        XCTAssertEqual(decoded.gestures.overviewGestureEnabled, true)
        XCTAssertEqual(decoded.gestures.overviewGestureFingerCount, .three)

        let oldConfig = String(decoding: encoded, as: UTF8.self)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("overviewGesture") }
            .joined(separator: "\n")
        let defaults = try SettingsTOMLCodec.decode(Data(oldConfig.utf8))
        XCTAssertEqual(defaults.gestures.overviewGestureEnabled, false)
        XCTAssertEqual(defaults.gestures.overviewGestureFingerCount, .four)
    }

    @MainActor
    func testOverviewOnlyGestureAvailabilityFollowsEnablement() {
        let settings = makeSettingsStore()
        settings.gestures.scrollEnabled = false
        settings.gestures.workspaceSwipeEnabled = false
        var changes: [Bool] = []
        settings.onTrackpadGestureAvailabilityChanged = { changes.append($0) }
        settings.gestures.overviewGestureEnabled = true
        XCTAssertTrue(settings.effectiveTrackpadGesturesEnabled)
        settings.gestures.overviewGestureEnabled = false
        XCTAssertFalse(settings.effectiveTrackpadGesturesEnabled)
        XCTAssertEqual(changes, [true, false])
    }

    func testOverviewGestureRejectsUnsupportedFingerCount() throws {
        let data = try defaultsWithReplacements(("overviewGestureFingerCount = 4", "overviewGestureFingerCount = 2"))
        XCTAssertThrowsError(try SettingsTOMLCodec.decode(data))
    }

    func testColumnScrollRejectsTwoFingers() throws {
        let data = try defaultsWithReplacements(("\nfingerCount = 3", "\nfingerCount = 2"))
        XCTAssertThrowsError(try SettingsTOMLCodec.decode(data))
    }

    func testWorkspaceSwipeSettingsRoundTrip() throws {
        let defaults = SettingsExport.defaults()
        XCTAssertFalse(defaults.gestures.workspaceSwipeEnabled)
        XCTAssertEqual(defaults.gestures.workspaceSwipeFingerCount, .three)
        XCTAssertEqual(defaults.gestures.workspaceSwipeAxis, .vertical)

        var export = defaults
        export.gestures.workspaceSwipeEnabled = true
        export.gestures.workspaceSwipeFingerCount = .four
        export.gestures.workspaceSwipeAxis = .horizontal
        let data = try SettingsTOMLCodec.encode(export)
        let encoded = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(encoded.contains("workspaceSwipeEnabled = true"))
        XCTAssertTrue(encoded.contains("workspaceSwipeFingerCount = 4"))
        XCTAssertTrue(encoded.contains("workspaceSwipeAxis = \"horizontal\""))

        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertTrue(decoded.gestures.workspaceSwipeEnabled)
        XCTAssertEqual(decoded.gestures.workspaceSwipeFingerCount, .four)
        XCTAssertEqual(decoded.gestures.workspaceSwipeAxis, .horizontal)
    }

    @MainActor
    func testNonfiniteTOMLScrollSensitivityNormalizesWhenApplied() throws {
        for literal in ["nan", "inf", "-inf"] {
            let data = try defaultsWithReplacements(
                ("scrollSensitivity = 5.0\n", "scrollSensitivity = \(literal)\n")
            )
            let export = try SettingsTOMLCodec.decode(data)
            let settings = makeSettingsStore()

            XCTAssertFalse(export.gestures.scrollSensitivity.isFinite)
            settings.applyExport(export)

            XCTAssertEqual(settings.gestures.scrollSensitivity, SettingsExport.defaults().gestures.scrollSensitivity)
            XCTAssertEqual(
                settings.toExport().gestures.scrollSensitivity,
                SettingsExport.defaults().gestures.scrollSensitivity
            )
        }
    }

    @MainActor
    func testProgrammaticScrollSensitivityNormalizesBeforeExport() {
        let settings = makeSettingsStore()

        settings.gestures.scrollSensitivity = .nan
        XCTAssertEqual(settings.gestures.scrollSensitivity, SettingsExport.defaults().gestures.scrollSensitivity)
        settings.gestures.scrollSensitivity = .infinity
        XCTAssertEqual(settings.gestures.scrollSensitivity, SettingsExport.defaults().gestures.scrollSensitivity)
        settings.gestures.scrollSensitivity = 0
        XCTAssertEqual(settings.gestures.scrollSensitivity, 0.1)
        settings.gestures.scrollSensitivity = 101
        XCTAssertEqual(settings.gestures.scrollSensitivity, 100)
        XCTAssertEqual(settings.toExport().gestures.scrollSensitivity, 100)
    }

    @MainActor
    func testUnsupportedWorkspaceSwipeValuesRejectDecode() throws {
        let cases: [(replacement: (String, String), keyPath: String)] = [
            (
                ("workspaceSwipeFingerCount = 3\n", "workspaceSwipeFingerCount = 5\n"),
                "gestures.workspaceSwipeFingerCount"
            ),
            (
                ("workspaceSwipeAxis = \"vertical\"\n", "workspaceSwipeAxis = \"diagonal\"\n"),
                "gestures.workspaceSwipeAxis"
            )
        ]

        for testCase in cases {
            let data = try defaultsWithReplacements(testCase.replacement)
            XCTAssertThrowsError(try SettingsTOMLCodec.decode(data), testCase.keyPath) { error in
                XCTAssertTrue(
                    SettingsTOMLCodec.diagnosticDescription(for: error).contains(testCase.keyPath),
                    testCase.keyPath
                )
            }
        }
    }

    @MainActor
    func testHorizontalWorkspaceSwipeSelectionSurvivesFingerCountCollision() {
        var export = SettingsExport.defaults()
        export.gestures.scrollEnabled = true
        export.gestures.fingerCount = .three
        export.gestures.workspaceSwipeEnabled = true
        export.gestures.workspaceSwipeFingerCount = .three
        export.gestures.workspaceSwipeAxis = .horizontal

        let settings = makeSettingsStore()
        settings.applyExport(export)

        XCTAssertEqual(settings.gestures.workspaceSwipeAxis, .horizontal)
        XCTAssertTrue(settings.gestures.workspaceSwipeAxisLockedToVertical)
        XCTAssertEqual(settings.gestures.effectiveWorkspaceSwipeAxis, .vertical)

        settings.gestures.workspaceSwipeFingerCount = .four

        XCTAssertEqual(settings.gestures.workspaceSwipeAxis, .horizontal)
        XCTAssertFalse(settings.gestures.workspaceSwipeAxisLockedToVertical)
        XCTAssertEqual(settings.gestures.effectiveWorkspaceSwipeAxis, .horizontal)
    }

    func testMalformedWorkspaceSwipeTypesRejectDecode() throws {
        let replacements = [
            ("workspaceSwipeEnabled = false\n", "workspaceSwipeEnabled = \"false\"\n"),
            ("workspaceSwipeFingerCount = 3\n", "workspaceSwipeFingerCount = \"three\"\n"),
            ("workspaceSwipeAxis = \"vertical\"\n", "workspaceSwipeAxis = 3\n")
        ]

        for (target, replacement) in replacements {
            let malformed = try defaultsWithReplacements((target, replacement))
            XCTAssertThrowsError(try SettingsTOMLCodec.decode(malformed))
        }
    }

    @MainActor
    func testMalformedExternalWorkspaceSwipeReloadDoesNotPartiallyApplyOrNotify() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSettingsCodecTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let persistence = SettingsFilePersistence(
            directory: root.appendingPathComponent("config", isDirectory: true),
            startWatching: true,
            deferSaves: false
        )
        let settings = SettingsStore(
            persistence: persistence,
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        settings.gestures.workspaceSwipeEnabled = true
        settings.gestures.workspaceSwipeFingerCount = .four
        settings.gestures.workspaceSwipeAxis = .horizontal
        var externalReloadCount = 0
        settings.onExternalSettingsReloaded = {
            externalReloadCount += 1
        }

        let malformed = try defaultsWithReplacements(
            ("workspaceSwipeAxis = \"vertical\"\n", "workspaceSwipeAxis = 3\n")
        )
        try malformed.write(to: persistence.fileURL, options: .atomic)
        XCTAssertNil(persistence.reloadIfChanged())
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(externalReloadCount, 0)
        XCTAssertTrue(settings.gestures.workspaceSwipeEnabled)
        XCTAssertEqual(settings.gestures.workspaceSwipeFingerCount, .four)
        XCTAssertEqual(settings.gestures.workspaceSwipeAxis, .horizontal)

        let valid = try SettingsTOMLCodec.encode(.defaults())
        try valid.write(to: persistence.fileURL, options: .atomic)
        for _ in 0 ..< 200 {
            if externalReloadCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(externalReloadCount, 1)
        XCTAssertFalse(settings.gestures.workspaceSwipeEnabled)
        XCTAssertEqual(settings.gestures.workspaceSwipeFingerCount, .three)
        XCTAssertEqual(settings.gestures.workspaceSwipeAxis, .vertical)
    }

    func testFocusLockModifierRoundTrips() throws {
        XCTAssertEqual(SettingsExport.defaults().focus.lockModifier, .off)
        XCTAssertTrue(
            String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
                .contains("lockModifier = \"off\"")
        )

        var export = SettingsExport.defaults()
        export.focus.lockModifier = .leftOption
        let data = try SettingsTOMLCodec.encode(export)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("lockModifier = \"leftOption\""))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).focus.lockModifier, .leftOption)
    }

    func testFocusCrossesMonitorAtEdgeRoundTrips() throws {
        XCTAssertFalse(SettingsExport.defaults().focus.crossesMonitorAtEdge)

        var export = SettingsExport.defaults()
        export.focus.crossesMonitorAtEdge = true
        let data = try SettingsTOMLCodec.encode(export)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("crossesMonitorAtEdge = true"))
        XCTAssertTrue(try SettingsTOMLCodec.decode(data).focus.crossesMonitorAtEdge)
    }

    func testMoveCrossesMonitorAtEdgeRoundTrips() throws {
        XCTAssertFalse(SettingsExport.defaults().focus.moveCrossesMonitorAtEdge)

        var export = SettingsExport.defaults()
        export.focus.moveCrossesMonitorAtEdge = true
        let data = try SettingsTOMLCodec.encode(export)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("moveCrossesMonitorAtEdge = true"))
        XCTAssertTrue(try SettingsTOMLCodec.decode(data).focus.moveCrossesMonitorAtEdge)
    }

    func testCursorContainmentRoundTrips() throws {
        XCTAssertFalse(SettingsExport.defaults().mouseWarp.constrainToArrangement)

        var export = SettingsExport.defaults()
        export.mouseWarp.constrainToArrangement = true
        let data = try SettingsTOMLCodec.encode(export)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("constrainToArrangement = true"))
        XCTAssertTrue(try SettingsTOMLCodec.decode(data).mouseWarp.constrainToArrangement)
    }

    func testUnknownEnumValueRejectsWholeFile() throws {
        let cases: [(line: String, invalid: String, key: String)] = [
            ("defaultLayoutType = \"\(LayoutType.niri.rawValue)\"", "defaultLayoutType = \"bsp\"", "defaultLayoutType"),
            ("lockModifier = \"\(FocusLockModifier.off.rawValue)\"", "lockModifier = \"hyper\"", "lockModifier"),
            ("mode = \"\(MonitorRoutingMode.macOS.rawValue)\"", "mode = \"sideways\"", "routing.mode"),
            (
                "centerFocusedColumn = \"\(CenterFocusedColumn.never.rawValue)\"",
                "centerFocusedColumn = \"sometimes\"",
                "centerFocusedColumn"
            ),
            ("singleWindowFit = \"fill\"", "singleWindowFit = \"stretch\"", "singleWindowFit"),
            (
                "windowLevel = \"\(WorkspaceBarWindowLevel.popup.rawValue)\"",
                "windowLevel = \"basement\"",
                "windowLevel"
            ),
            (
                "position = \"\(WorkspaceBarPosition.overlappingMenuBar.rawValue)\"",
                "position = \"sideways\"",
                "workspaceBar.position"
            ),
            (
                "notchMode = \"\(WorkspaceBarNotchMode.moveBelowMenuBar.rawValue)\"",
                "notchMode = \"ignoreNotch\"",
                "notchMode"
            ),
            (
                "revealModifier = \"\(WorkspaceBarRevealModifier.off.rawValue)\"",
                "revealModifier = \"fn\"",
                "revealModifier"
            ),
            (
                "scrollModifierKey = \"\(ScrollModifierKey.optionShift.rawValue)\"",
                "scrollModifierKey = \"fn\"",
                "scrollModifierKey"
            ),
            (
                "mouseMoveModifierKey = \"\(MouseMoveModifierKey.option.rawValue)\"",
                "mouseMoveModifierKey = \"shift\"",
                "mouseMoveModifierKey"
            ),
            (
                "mouseResizeModifierKey = \"\(MouseResizeModifierKey.option.rawValue)\"",
                "mouseResizeModifierKey = \"hyperspace\"",
                "mouseResizeModifierKey"
            ),
            ("fingerCount = \(GestureFingerCount.three.rawValue)\n", "fingerCount = 7\n", "fingerCount"),
            (
                "trackpadScrollStyle = \"\(TrackpadScrollStyle.snap.rawValue)\"",
                "trackpadScrollStyle = \"drift\"",
                "trackpadScrollStyle"
            ),
            (
                "workspaceSwipeFingerCount = \(GestureFingerCount.three.rawValue)\n",
                "workspaceSwipeFingerCount = 7\n",
                "workspaceSwipeFingerCount"
            ),
            (
                "workspaceSwipeAxis = \"\(WorkspaceSwipeAxis.vertical.rawValue)\"",
                "workspaceSwipeAxis = \"diagonal\"",
                "workspaceSwipeAxis"
            ),
            (
                "position = \"\(QuakeTerminalPosition.center.rawValue)\"",
                "position = \"corner\"",
                "quakeTerminal.position"
            ),
            (
                "backgroundEffect = \"\(QuakeTerminalBackgroundEffect.standardBlur.rawValue)\"",
                "backgroundEffect = \"futureGlass\"",
                "backgroundEffect"
            ),
            (
                "monitorMode = \"\(QuakeTerminalMonitorMode.focusedWindow.rawValue)\"",
                "monitorMode = \"everywhere\"",
                "monitorMode"
            ),
            ("mode = \"\(AppearanceMode.dark.rawValue)\"", "mode = \"sepia\"", "appearance.mode")
        ]
        let defaults = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        XCTAssertNoThrow(try SettingsTOMLCodec.decode(Data(defaults.utf8)))

        for testCase in cases {
            XCTAssertTrue(defaults.contains(testCase.line), testCase.key)
            let data = Data(defaults.replacingOccurrences(of: testCase.line, with: testCase.invalid).utf8)
            XCTAssertThrowsError(try SettingsTOMLCodec.decode(data), testCase.key) { error in
                XCTAssertTrue(
                    SettingsTOMLCodec.diagnosticDescription(for: error).contains(testCase.key),
                    "\(testCase.key): \(SettingsTOMLCodec.diagnosticDescription(for: error))"
                )
            }
        }
    }

    func testMonitorOverrideUnknownEnumValuesRejectDecode() throws {
        var export = SettingsExport.defaults()
        export.monitorNiriSettings = [
            MonitorNiriSettings(monitorName: "Override", singleWindowFit: SingleWindowFit(mode: .containerPrimarySpan))
        ]
        export.monitorDwindleSettings = [
            MonitorDwindleSettings(
                monitorName: "Override",
                singleWindowFit: SingleWindowFit(mode: .containerPrimarySpan)
            )
        ]
        let toml = String(decoding: try SettingsTOMLCodec.encode(export), as: UTF8.self)
        XCTAssertEqual(toml.components(separatedBy: "singleWindowFit = \"container_primary_span\"").count, 3)

        let invalid = toml.replacingOccurrences(
            of: "singleWindowFit = \"container_primary_span\"",
            with: "singleWindowFit = \"stretch\""
        )

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(invalid.utf8))) { error in
            XCTAssertTrue(SettingsTOMLCodec.diagnosticDescription(for: error).contains("singleWindowFit"))
        }
    }

    func testEmptySingleWindowFitRejectsDecode() throws {
        let data = try defaultsWithReplacements(("singleWindowFit = \"fill\"", "singleWindowFit = \"\""))

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(data)) { error in
            XCTAssertTrue(SettingsTOMLCodec.diagnosticDescription(for: error).contains("singleWindowFit"))
        }
    }

    private func defaultsWithReplacements(_ replacements: (String, String)...) throws -> Data {
        var toml = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        for (target, replacement) in replacements {
            toml = toml.replacingOccurrences(of: target, with: replacement)
        }
        return Data(toml.utf8)
    }

    private func defaultsWithSuffix(_ suffix: String) throws -> Data {
        var toml = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        toml += suffix
        toml += "\n"
        return Data(toml.utf8)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSettingsCodecTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }

    private func tomlValue(for key: String, in toml: String) -> String? {
        let prefix = "\(key) = "
        return toml
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private func parseOffsetDateTime(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]

        return fractional.date(from: value) ?? wholeSeconds.date(from: value)
    }
}
