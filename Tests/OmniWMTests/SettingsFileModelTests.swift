// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
@testable import OmniWM
import XCTest

final class SettingsFileModelTests: XCTestCase {
    func testScrollModifierChoicesRoundTripWithOptionShiftDefault() throws {
        var export = SettingsExport.defaults()
        XCTAssertEqual(export.gestures.scrollModifierKey, .optionShift)
        for modifier in ScrollModifierKey.allCases {
            export.gestures.scrollModifierKey = modifier
            let data = try SettingsLuauDocument.initialSource(export)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(
                "scrollModifierKey = \"\(modifier.rawValue)\""
            ))
            let result = try SettingsLuauDocument(data)
            XCTAssertEqual(result.export, export)
        }
    }

    func testAnimationSpeedDefaultsAndRoundTrips() throws {
        var export = SettingsExport.defaults()
        XCTAssertEqual(export.animationSpeed, 1)
        for speed in [0.25, 1, 1.75, 2, 4] {
            export.animationSpeed = speed
            let data = try SettingsLuauDocument.initialSource(export)
            XCTAssertEqual(try SettingsLuauFixture.decode(data), export)
        }
    }

    func testOmittedAnimationSpeedUsesDefault() throws {
        XCTAssertEqual(
            try SettingsLuauFixture.decode(Data("return {}".utf8)).animationSpeed,
            SettingsExport.defaults().animationSpeed
        )
    }

    func testAnimationSpeedNormalizesOutOfRangeAndRejectsNonfiniteInput() throws {
        for (literal, expected) in [("0", 0.25), ("-2.0", 0.25), ("10.0", 4)] {
            let source = Data("return { general = { animationSpeed = \(literal) } }".utf8)
            XCTAssertEqual(try SettingsLuauFixture.decode(source).animationSpeed, expected)
        }
        for literal in ["math.huge", "(0 / 0)"] {
            XCTAssertThrowsError(try SettingsLuauDocument(Data("return { general = { animationSpeed = \(literal) } }"
                    .utf8)))
        }
    }

    func testWorkspaceAutoBackAndForthDefaultsOffAndRoundTrips() throws {
        var export = SettingsExport.defaults()
        XCTAssertFalse(export.workspaceAutoBackAndForth)
        for enabled in [false, true] {
            export.workspaceAutoBackAndForth = enabled
            let data = try SettingsLuauDocument.initialSource(export)
            XCTAssertEqual(try SettingsLuauFixture.decode(data), export)
        }

        let omitted = try canonicalDefaultLines { lines in
            let index = try XCTUnwrap(lines
                .firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("workspaceAutoBackAndForth = ") })
            lines.remove(at: index)
        }
        let result = try SettingsLuauDocument(omitted)
        XCTAssertFalse(result.export.workspaceAutoBackAndForth)
    }

    @MainActor
    func testWorkspaceSwitchWrapAroundDefaultsOnAndRoundTripsThroughStore() throws {
        let settings = makeSettingsStore()
        XCTAssertTrue(settings.workspaces.switchWrapAround)
        settings.workspaces.switchWrapAround = false

        let data = try SettingsLuauDocument.initialSource(settings.toExport())
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("workspaceSwitchWrapAround = false"))

        settings.workspaces.switchWrapAround = true
        settings.applyExport(try SettingsLuauDocument(data).export)
        XCTAssertFalse(settings.workspaces.switchWrapAround)
        XCTAssertFalse(settings.toExport().workspaceSwitchWrapAround)

        let omitted = try canonicalDefaultLines { lines in
            let index = try XCTUnwrap(lines
                .firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("workspaceSwitchWrapAround = ") })
            lines.remove(at: index)
        }
        let result = try SettingsLuauDocument(omitted)
        settings.applyExport(result.export)
        XCTAssertTrue(settings.workspaces.switchWrapAround)
    }

    func testPausePalettePasteDuringSecureInputDefaultsOnAndRoundTrips() throws {
        var export = SettingsExport.defaults()
        XCTAssertTrue(export.pausePalettePasteDuringSecureInput)
        for enabled in [false, true] {
            export.pausePalettePasteDuringSecureInput = enabled
            let data = try SettingsLuauDocument.initialSource(export)
            XCTAssertEqual(try SettingsLuauFixture.decode(data), export)
        }

        let omitted = try canonicalDefaultLines { lines in
            let index = try XCTUnwrap(lines
                .firstIndex {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix("pausePalettePasteDuringSecureInput = ")
                })
            lines.remove(at: index)
        }
        let result = try SettingsLuauDocument(omitted)
        XCTAssertTrue(result.export.pausePalettePasteDuringSecureInput)
    }

    @MainActor
    func testSecureInputExplanationDefaultsOnAndRoundTrips() throws {
        let settings = makeSettingsStore()
        XCTAssertTrue(settings.showSecureInputExplanation)

        settings.showSecureInputExplanation = false
        let data = try SettingsLuauDocument.initialSource(settings.toExport())
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("showSecureInputExplanation = false"))

        settings.showSecureInputExplanation = true
        settings.applyExport(try SettingsLuauDocument(data).export)
        XCTAssertFalse(settings.showSecureInputExplanation)
        XCTAssertFalse(settings.toExport().showSecureInputExplanation)

        let omitted = try SettingsLuauDocument(Data("return {}".utf8))
        settings.applyExport(omitted.export)
        XCTAssertTrue(settings.showSecureInputExplanation)
    }

    func testSlideWorkspaceSwitchesDefaultsOffAndRoundTrips() throws {
        var export = SettingsExport.defaults()
        XCTAssertFalse(export.slideWorkspaceSwitches)
        for enabled in [false, true] {
            export.slideWorkspaceSwitches = enabled
            let data = try SettingsLuauDocument.initialSource(export)
            XCTAssertEqual(try SettingsLuauFixture.decode(data), export)
        }

        let omitted = try canonicalDefaultLines { lines in
            let index = try XCTUnwrap(lines
                .firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("slideWorkspaceSwitches = ") })
            lines.remove(at: index)
        }
        let result = try SettingsLuauDocument(omitted)
        XCTAssertFalse(result.export.slideWorkspaceSwitches)
    }

    func testTabRailAppIconsDefaultsAndRoundTrips() throws {
        var export = SettingsExport.defaults()
        XCTAssertFalse(export.tabRailAppIcons)

        for enabled in [false, true] {
            export.tabRailAppIcons = enabled
            let data = try SettingsLuauDocument.initialSource(export)
            XCTAssertEqual(
                try SettingsLuauFixture.fields(in: data)["appearance"]?["tabRailAppIcons"],
                .boolean(enabled)
            )
            XCTAssertEqual(try SettingsLuauFixture.decode(data), export)
        }
    }

    func testMissingTabRailAppIconsDefaultsToCompact() throws {
        let withoutKey = try canonicalDefaultLines { lines in
            let index = try XCTUnwrap(lines.firstIndex { $0.contains("tabRailAppIcons = false") })
            lines.remove(at: index)
        }

        let result = try SettingsLuauDocument(withoutKey)

        XCTAssertFalse(result.export.tabRailAppIcons)
    }

    func testDefaultLuauOmitsUnassignableHotkeyActions() throws {
        let source = String(
            decoding: try SettingsLuauDocument.initialSource(.defaults()),
            as: UTF8.self
        )

        for id in ["consumeOrExpelWindowLeft", "consumeOrExpelWindowRight"] {
            XCTAssertFalse(source.contains(#"id = "\#(id)""#))
        }
    }

    func testLuauRejectsUnassignableHotkeyActions() throws {
        for id in ["consumeOrExpelWindowLeft", "consumeOrExpelWindowRight"] {
            let source = Data("return { hotkeys = { { id = '\(id)', binding = 'Option+H' } } }".utf8)
            XCTAssertThrowsError(try SettingsLuauFixture.decode(source)) { error in
                XCTAssertTrue(error.localizedDescription
                    .contains(HotkeyBindingResolutionError.unassignableActionID(id).localizedDescription))
            }
        }
    }

    func testLuauTreatsAMissingKnownHotkeyActionAsUnassigned() throws {
        let firstID = try XCTUnwrap(HotkeyBindingRegistry.defaults().first?.id)
        var export = SettingsExport.defaults()
        export.hotkeyBindings.removeAll { $0.id == firstID }
        let result = try SettingsLuauDocument(SettingsLuauDocument.initialSource(export))
        let bindings = result.export.hotkeyBindings
        XCTAssertEqual(bindings.first { $0.id == firstID }?.binding, .unassigned)
        XCTAssertEqual(
            bindings.filter { $0.id != firstID },
            SettingsExport.defaults().hotkeyBindings.filter { $0.id != firstID }
        )
    }

    func testMissingFloatingFocusToggleUsesDefault() throws {
        var export = SettingsExport.defaults()
        export.hotkeyBindings.removeAll { $0.id == "toggleFloatingFocus" }
        XCTAssertEqual(
            try SettingsLuauFixture.decode(SettingsLuauDocument.initialSource(export)).hotkeyBindings,
            SettingsExport.defaults().hotkeyBindings
        )
    }

    func testLuauRejectsDuplicateHotkeyAction() throws {
        let firstID = try XCTUnwrap(HotkeyBindingRegistry.defaults().first?.id)
        let row = "{ id = '\(firstID)', binding = 'Option+H' }"
        let source = Data("return { hotkeys = { \(row), \(row) } }".utf8)
        XCTAssertThrowsError(try SettingsLuauFixture.decode(source)) { error in
            XCTAssertTrue(error.localizedDescription
                .contains(HotkeyBindingResolutionError.duplicateActionID(firstID).localizedDescription))
        }
    }

    func testMissingFieldsUseNativeDefaults() throws {
        let result = try SettingsLuauFixture.decode(Data("return { focus = {}, gaps = {} }".utf8))
        let defaults = SettingsExport.defaults()
        XCTAssertEqual(result.focus.followsMouse, defaults.focus.followsMouse)
        XCTAssertEqual(result.focus.raiseOnMouseFocus, defaults.focus.raiseOnMouseFocus)
        XCTAssertEqual(result.gaps.fullscreenUsesOuterGaps, defaults.gaps.fullscreenUsesOuterGaps)
    }

    func testRaiseOnMouseFocusDefaultsAndRoundTrips() throws {
        var export = SettingsExport.defaults()

        XCTAssertFalse(export.focus.raiseOnMouseFocus)
        XCTAssertTrue(
            String(decoding: try SettingsLuauDocument.initialSource(export), as: UTF8.self)
                .contains("raiseOnMouseFocus = false")
        )

        export.focus.raiseOnMouseFocus = true
        let data = try SettingsLuauDocument.initialSource(export)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("raiseOnMouseFocus = true"))
        XCTAssertTrue(try SettingsLuauFixture.decode(data).focus.raiseOnMouseFocus)
    }

    func testLuauRejectsCorruptHyperSettings() throws {
        for (key, value) in [("systemHyperTrigger", "NotAKey"), ("hyperKeyModifiers", "Control")] {
            let source = Data("return { general = { \(key) = '\(value)' } }".utf8)
            XCTAssertThrowsError(try SettingsLuauFixture.decode(source)) { error in
                XCTAssertTrue(error.localizedDescription.contains("general.\(key)"), error.localizedDescription)
            }
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
        let withoutFirst = try HotkeyBindingRegistry.resolve(Array(complete.dropFirst()))
        XCTAssertEqual(withoutFirst.first { $0.id == firstID }?.binding, .unassigned)
        XCTAssertEqual(
            withoutFirst.filter { $0.id != firstID },
            try HotkeyBindingRegistry.resolve(complete).filter { $0.id != firstID }
        )

        let withDuplicate = try complete + [XCTUnwrap(complete.first)]
        XCTAssertThrowsError(try HotkeyBindingRegistry.resolve(withDuplicate)) { error in
            XCTAssertEqual(error as? HotkeyBindingResolutionError, .duplicateActionID(firstID))
        }
    }

    func testAConfigFromBeforeUndoGivesUndoAndRedoTheirKeys() throws {
        let defaults = HotkeyBindingRegistry.defaults()
        let older = defaults
            .filter { !HotkeyBindingRegistry.idsGivenTheirDefaultWhenMissing.contains($0.id) }
            .map { PersistedHotkeyBinding(id: $0.id, trigger: $0.binding) }

        let resolved = try HotkeyBindingRegistry.resolve(older)

        for id in ["undo", "redo"] {
            let expected = try XCTUnwrap(defaults.first { $0.id == id }?.binding)
            XCTAssertNotEqual(expected, .unassigned, id)
            XCTAssertEqual(resolved.first { $0.id == id }?.binding, expected, id)
        }
    }

    func testUndoKeepsNoKeyWhenAnotherCommandHasItOrTheUserClearedIt() throws {
        let defaults = HotkeyBindingRegistry.defaults()
        let undoKey = try XCTUnwrap(defaults.first { $0.id == "undo" }?.binding)
        let redoKey = try XCTUnwrap(defaults.first { $0.id == "redo" }?.binding)
        var older = defaults
            .filter { !HotkeyBindingRegistry.idsGivenTheirDefaultWhenMissing.contains($0.id) }
            .map { PersistedHotkeyBinding(id: $0.id, trigger: $0.binding) }
        let other = older[0].id
        older[0] = PersistedHotkeyBinding(id: other, trigger: undoKey)

        let taken = try HotkeyBindingRegistry.resolve(older)

        XCTAssertEqual(taken.first { $0.id == other }?.binding, undoKey)
        XCTAssertEqual(taken.first { $0.id == "undo" }?.binding, .unassigned)
        XCTAssertEqual(taken.first { $0.id == "redo" }?.binding, redoKey)

        let cleared = defaults.map {
            PersistedHotkeyBinding(id: $0.id, trigger: $0.id == "undo" ? .unassigned : $0.binding)
        }
        let resolved = try HotkeyBindingRegistry.resolve(cleared)

        XCTAssertEqual(resolved.first { $0.id == "undo" }?.binding, .unassigned)
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

            let source = "return { hotkeys = { { binding = 'Option+H', id = '\(id)' } } }"
            try Data(source.utf8).write(to: directory.appendingPathComponent(SettingsFilePersistence.fileName))

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
        let canonical = String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
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

        let data = try SettingsLuauDocument.initialSource(export)
        let decoded = try SettingsLuauFixture.decode(data)

        XCTAssertTrue(decoded.gaps.fullscreenUsesOuterGaps)
        XCTAssertEqual(decoded.monitorGapSettings, export.monitorGapSettings)
        let source = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(source.contains("innerGap = 6,"))
        XCTAssertTrue(source.contains("fullscreenUsesOuterGaps = true"))
        XCTAssertTrue(source.contains("fullscreenUsesOuterGaps = false"))
    }

    func testMonitorRankingRoundTripsInOrderAndTableIsOmittedWhenEmpty() throws {
        let defaults = String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
        XCTAssertFalse(defaults.contains("monitors = {"))
        XCTAssertFalse(defaults.contains("ranking"))
        XCTAssertEqual(try SettingsLuauFixture.decode(Data(defaults.utf8)).monitorRanking, [])

        var export = SettingsExport.defaults()
        export.monitorRanking = [
            OutputId(displayUUID: "22222222-2222-2222-2222-222222222222", name: "DELL U3423WE"),
            OutputId(displayId: 7, name: "LG HDR 4K"),
            OutputId(name: "Built-in Retina Display")
        ]

        let data = try SettingsLuauDocument.initialSource(export)
        let source = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(source.contains("ranking = {"), source)
        XCTAssertTrue(source.contains("displayUUID = \"22222222-2222-2222-2222-222222222222\""), source)

        let decoded = try SettingsLuauFixture.decode(data)
        XCTAssertEqual(decoded.monitorRanking.map(\.name), ["DELL U3423WE", "LG HDR 4K", "Built-in Retina Display"])
        XCTAssertEqual(decoded.monitorRanking[0].displayUUID, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(decoded.monitorRanking[1].displayId, 7)
        XCTAssertNil(decoded.monitorRanking[2].displayUUID)
        XCTAssertNil(decoded.monitorRanking[2].displayId)
    }

    @MainActor
    func testUnknownSettingRejectsSaveAndPreservesUserSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSettingsCodecTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let input = Data("return { general = { futureSetting = 'keep-me' } }".utf8)
        let fileURL = directory.appendingPathComponent(SettingsFilePersistence.fileName)
        try input.write(to: fileURL)
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false)
        let outcome = persistence.loadOutcome()
        XCTAssertNil(outcome.export)
        XCTAssertTrue(String(describing: outcome.notice).contains("general.futureSetting"))
        XCTAssertThrowsError(try persistence.saveImmediately(.defaults()))
        XCTAssertEqual(try Data(contentsOf: fileURL), input)
    }

    func testTrackpadScrollStyleRoundTrips() throws {
        XCTAssertEqual(SettingsExport.defaults().gestures.trackpadScrollStyle, .snap)

        var export = SettingsExport.defaults()
        export.gestures.trackpadScrollStyle = .momentum
        let data = try SettingsLuauDocument.initialSource(export)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("trackpadScrollStyle = \"momentum\""))
        XCTAssertEqual(try SettingsLuauFixture.decode(data).gestures.trackpadScrollStyle, .momentum)
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

    func testOverviewGestureSettingsRoundTripAndExistingConfigDefaults() throws {
        var export = SettingsExport.defaults()
        export.gestures.overviewGestureEnabled = true
        export.gestures.overviewGestureFingerCount = .three
        let encoded = try SettingsLuauDocument.initialSource(export)
        let decoded = try SettingsLuauFixture.decode(encoded)
        XCTAssertEqual(decoded.gestures.overviewGestureEnabled, true)
        XCTAssertEqual(decoded.gestures.overviewGestureFingerCount, .three)

        let oldConfig = String(decoding: encoded, as: UTF8.self)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("overviewGesture") }
            .joined(separator: "\n")
        let defaults = try SettingsLuauFixture.decode(Data(oldConfig.utf8))
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

    func testWorkspaceSwipeSettingsRoundTrip() throws {
        let defaults = SettingsExport.defaults()
        XCTAssertFalse(defaults.gestures.workspaceSwipeEnabled)
        XCTAssertEqual(defaults.gestures.workspaceSwipeFingerCount, .three)
        XCTAssertEqual(defaults.gestures.workspaceSwipeAxis, .vertical)

        var export = defaults
        export.gestures.workspaceSwipeEnabled = true
        export.gestures.workspaceSwipeFingerCount = .four
        export.gestures.workspaceSwipeAxis = .horizontal
        let data = try SettingsLuauDocument.initialSource(export)
        let encoded = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(encoded.contains("workspaceSwipeEnabled = true"))
        XCTAssertTrue(encoded.contains("workspaceSwipeFingerCount = 4"))
        XCTAssertTrue(encoded.contains("workspaceSwipeAxis = \"horizontal\""))

        let decoded = try SettingsLuauFixture.decode(data)
        XCTAssertTrue(decoded.gestures.workspaceSwipeEnabled)
        XCTAssertEqual(decoded.gestures.workspaceSwipeFingerCount, .four)
        XCTAssertEqual(decoded.gestures.workspaceSwipeAxis, .horizontal)
    }

    @MainActor
    func testNonfiniteScrollSensitivityIsRejectedOnLoad() throws {
        for literal in ["math.huge", "-math.huge", "(0 / 0)"] {
            let source = Data("return { gestures = { scrollSensitivity = \(literal) } }".utf8)
            XCTAssertThrowsError(try SettingsLuauDocument(source))
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
    func testWorkspaceSwipeEdgeBehaviorRoundTripsAndDefaultsToCycleWhenOmitted() throws {
        var export = SettingsExport.defaults()
        XCTAssertEqual(export.gestures.workspaceSwipeEdgeBehavior, .cycle)
        export.gestures.workspaceSwipeEdgeBehavior = .onePast
        let data = try SettingsLuauDocument.initialSource(export)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(encoded.contains("workspaceSwipeEdgeBehavior = \"onePast\""))
        XCTAssertEqual(try SettingsLuauFixture.decode(data).gestures.workspaceSwipeEdgeBehavior, .onePast)

        let omitted = encoded.replacingOccurrences(of: "workspaceSwipeEdgeBehavior = \"onePast\",\n", with: "")
        let decoded = try SettingsLuauFixture.decode(Data(omitted.utf8))
        let settings = makeSettingsStore()
        settings.gestures.apply(decoded.gestures)
        XCTAssertEqual(settings.gestures.workspaceSwipeEdgeBehavior, .cycle)
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

    func testMalformedOrUnsupportedSettingValuesRejectDecode() throws {
        let replacements = [
            ("workspaceSwipeEnabled = false,\n", "workspaceSwipeEnabled = \"false\",\n"),
            ("workspaceSwipeFingerCount = 3,\n", "workspaceSwipeFingerCount = \"three\",\n"),
            ("workspaceSwipeAxis = \"vertical\",\n", "workspaceSwipeAxis = 3,\n"),
            ("overviewGestureFingerCount = 4", "overviewGestureFingerCount = 2"),
            ("fingerCount = 3", "fingerCount = 2")
        ]

        for (target, replacement) in replacements {
            let malformed = try defaultsWithReplacements((target, replacement))
            XCTAssertThrowsError(try SettingsLuauFixture.decode(malformed), replacement)
        }
    }

    @MainActor
    func testMalformedExternalWorkspaceSwipeReloadDoesNotPartiallyApplyOrNotify() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSettingsCodecTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let persistence = SettingsFilePersistence(
            directory: root.appendingPathComponent("config", isDirectory: true),
            startWatching: false,
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
        var working = settings.toExport()
        working.gestures.workspaceSwipeEnabled = true
        working.gestures.workspaceSwipeFingerCount = .four
        working.gestures.workspaceSwipeAxis = .horizontal
        try SettingsLuauDocument.initialSource(working).write(to: persistence.fileURL, options: .atomic)
        persistence.handlePossibleSettingsFileChange()
        var noticeChangeCount = 0
        settings.onConfigNoticeChanged = {
            noticeChangeCount += 1
        }
        var externalReloadCount = 0
        settings.onExternalSettingsReloaded = {
            externalReloadCount += 1
        }

        let malformed = Data("return {gestures = { workspaceSwipeAxis = 3 }}".utf8)
        try malformed.write(to: persistence.fileURL, options: .atomic)
        persistence.handlePossibleSettingsFileChange()

        guard case let .invalidRejected(reason) = settings.configNotice else {
            return XCTFail("Malformed external settings must publish a rejection notice")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(noticeChangeCount, 1)
        XCTAssertEqual(try Data(contentsOf: persistence.fileURL), malformed)
        persistence.handlePossibleSettingsFileChange()
        XCTAssertEqual(noticeChangeCount, 1)
        XCTAssertEqual(externalReloadCount, 0)
        XCTAssertTrue(settings.gestures.workspaceSwipeEnabled)
        XCTAssertEqual(settings.gestures.workspaceSwipeFingerCount, .four)
        XCTAssertEqual(settings.gestures.workspaceSwipeAxis, .horizontal)

        let valid = try SettingsLuauDocument.initialSource(.defaults())
        try valid.write(to: persistence.fileURL, options: .atomic)
        persistence.handlePossibleSettingsFileChange()

        XCTAssertNil(settings.configNotice)
        XCTAssertEqual(noticeChangeCount, 2)
        XCTAssertEqual(externalReloadCount, 1)
        XCTAssertFalse(settings.gestures.workspaceSwipeEnabled)
        XCTAssertEqual(settings.gestures.workspaceSwipeFingerCount, .three)
        XCTAssertEqual(settings.gestures.workspaceSwipeAxis, .vertical)
    }

    func testFocusLockModifierRoundTrips() throws {
        XCTAssertEqual(SettingsExport.defaults().focus.lockModifier, .off)
        XCTAssertTrue(
            String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
                .contains("lockModifier = \"off\"")
        )

        var export = SettingsExport.defaults()
        export.focus.lockModifier = .leftOption
        let data = try SettingsLuauDocument.initialSource(export)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("lockModifier = \"leftOption\""))
        XCTAssertEqual(try SettingsLuauFixture.decode(data).focus.lockModifier, .leftOption)
    }

    func testBooleanSettingsRoundTrip() throws {
        let cases: [(key: String, path: WritableKeyPath<SettingsExport, Bool>)] = [
            ("crossesMonitorAtEdge", \.focus.crossesMonitorAtEdge),
            ("moveCrossesMonitorAtEdge", \.focus.moveCrossesMonitorAtEdge),
            ("constrainToArrangement", \.mouseWarp.constrainToArrangement)
        ]
        for (key, path) in cases {
            XCTAssertFalse(SettingsExport.defaults()[keyPath: path], key)

            var export = SettingsExport.defaults()
            export[keyPath: path] = true
            let data = try SettingsLuauDocument.initialSource(export)

            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\(key) = true"), key)
            XCTAssertTrue(try SettingsLuauFixture.decode(data)[keyPath: path], key)
        }
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
            ("fingerCount = \(GestureFingerCount.three.rawValue),\n", "fingerCount = 7,\n", "fingerCount"),
            (
                "trackpadScrollStyle = \"\(TrackpadScrollStyle.snap.rawValue)\"",
                "trackpadScrollStyle = \"drift\"",
                "trackpadScrollStyle"
            ),
            (
                "workspaceSwipeFingerCount = \(GestureFingerCount.three.rawValue),\n",
                "workspaceSwipeFingerCount = 7,\n",
                "workspaceSwipeFingerCount"
            ),
            (
                "workspaceSwipeAxis = \"\(WorkspaceSwipeAxis.vertical.rawValue)\"",
                "workspaceSwipeAxis = \"diagonal\"",
                "gestures.workspaceSwipeAxis"
            ),
            (
                "workspaceSwipeEdgeBehavior = \"\(WorkspaceSwipeEdgeBehavior.cycle.rawValue)\"",
                "workspaceSwipeEdgeBehavior = \"bounce\"",
                "gestures.workspaceSwipeEdgeBehavior"
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
            (
                "workspaceSwipeFingerCount = 3,\n",
                "workspaceSwipeFingerCount = 5,\n",
                "gestures.workspaceSwipeFingerCount"
            ),
            ("revealModifier = \"off\"", "revealModifier = \"garbage\"", "workspaceBar.revealModifier")
        ]
        let defaults = String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
        XCTAssertNoThrow(try SettingsLuauFixture.decode(Data(defaults.utf8)))

        for testCase in cases {
            XCTAssertTrue(defaults.contains(testCase.line), testCase.key)
            let data = Data(defaults.replacingOccurrences(of: testCase.line, with: testCase.invalid).utf8)
            XCTAssertThrowsError(try SettingsLuauFixture.decode(data), testCase.key) { error in
                XCTAssertTrue(
                    SettingsLuauError.diagnosticDescription(for: error).contains(testCase.key),
                    "\(testCase.key): \(SettingsLuauError.diagnosticDescription(for: error))"
                )
            }
        }
    }

    func testUnknownStringAndIntegerChoicesShowTheirLuauValues() throws {
        let cases = [
            (
                "workspaceSwipeAxis",
                "'diagonal'",
                #"Unsupported choice "diagonal". Expected one of "horizontal", "vertical"."#
            ),
            ("workspaceSwipeFingerCount", "7", "Unsupported choice 7. Expected one of 2, 3, 4.")
        ]
        for (field, invalid, reason) in cases {
            let source = ["return { gestures = {", "\(field) = \(invalid)", "} }"]
            let fieldLine = try XCTUnwrap(source.firstIndex { $0.hasPrefix(field) }) + 1
            XCTAssertThrowsError(try SettingsLuauDocument(Data(source.joined(separator: "\n").utf8))) {
                XCTAssertEqual($0.localizedDescription, "settings.luau:\(fieldLine): gestures.\(field): \(reason)")
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
        let source = String(decoding: try SettingsLuauDocument.initialSource(export), as: UTF8.self)
        XCTAssertEqual(source.components(separatedBy: "singleWindowFit = \"container_primary_span\"").count, 3)
        XCTAssertNoThrow(try SettingsLuauFixture.decode(Data(source.utf8)))
        for table in ["monitorNiriOverrides", "monitorDwindleOverrides"] {
            var lines = source.components(separatedBy: "\n")
            let header = try XCTUnwrap(lines.firstIndex { $0.contains("\(table) = {") })
            let value = try XCTUnwrap(lines.indices.dropFirst(header + 1).first {
                lines[$0].contains("singleWindowFit = \"container_primary_span\"")
            })
            lines[value] = "singleWindowFit = \"stretch\","
            let invalid = Data(lines.joined(separator: "\n").utf8)
            XCTAssertThrowsError(try SettingsLuauFixture.decode(invalid), table) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("\(table)[0].singleWindowFit"),
                    error.localizedDescription
                )
            }
        }
    }

    func testEmptySingleWindowFitRejectsDecode() throws {
        let data = try defaultsWithReplacements(("singleWindowFit = \"fill\"", "singleWindowFit = \"\""))

        XCTAssertThrowsError(try SettingsLuauFixture.decode(data)) { error in
            XCTAssertTrue(SettingsLuauError.diagnosticDescription(for: error).contains("singleWindowFit"))
        }
    }

    private func defaultsWithReplacements(_ replacements: (String, String)...) throws -> Data {
        var source = String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
        for (target, replacement) in replacements {
            source = source.replacingOccurrences(of: target, with: replacement)
        }
        return Data(source.utf8)
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
}
