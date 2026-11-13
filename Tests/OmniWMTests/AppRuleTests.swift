// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class AppRuleTests: XCTestCase {
    func testNormalizeSingleTitleDropsSubstringWhenBothSet() {
        let rule = AppRule(
            bundleId: "com.test.app",
            titleSubstring: "Main",
            titleRegex: "^Main$",
            layout: .float
        )
        XCTAssertNil(rule.titleSubstring)
        XCTAssertEqual(rule.titleRegex, "^Main$")
    }

    func testNormalizeKeepsLoneTitleMatchers() {
        let substring = AppRule(bundleId: "a", titleSubstring: "Main", layout: .float)
        XCTAssertEqual(substring.titleSubstring, "Main")
        XCTAssertNil(substring.titleRegex)

        let regex = AppRule(bundleId: "a", titleRegex: "^Main$", layout: .float)
        XCTAssertNil(regex.titleSubstring)
        XCTAssertEqual(regex.titleRegex, "^Main$")
    }

    func testNormalizeSingleTitleAppliesOnDecode() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","bundleId":"com.test.app",\
        "titleSubstring":"Main","titleRegex":"^Main$","layout":"float"}
        """
        let rule = try JSONDecoder().decode(AppRule.self, from: Data(json.utf8))
        XCTAssertNil(rule.titleSubstring)
        XCTAssertEqual(rule.titleRegex, "^Main$")
    }

    func testHasEffect() {
        XCTAssertFalse(AppRule(bundleId: "com.test.app").hasEffect)
        XCTAssertFalse(AppRule(bundleId: "com.test.app", appNameSubstring: "Test").hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", layout: .float).hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", assignToWorkspace: "2").hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: 0.05).hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: 1.0).hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", minWidth: 400).hasEffect)
        XCTAssertTrue(AppRule(bundleId: "com.test.app", minHeight: 300).hasEffect)
    }

    func testInvalidInitialContainerPrimarySpanDoesNotCountAsEffect() {
        for value in [0.049, 1.001, .nan, .infinity, -.infinity] {
            let rule = AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: value)
            XCTAssertNil(rule.validInitialContainerPrimarySpan)
            XCTAssertFalse(rule.hasEffect)
        }
    }

    func testScratchpadRoundTripsThroughJSONAndTOML() throws {
        let rule = AppRule(bundleId: "com.test.app", scratchpad: 3)
        let json = try JSONDecoder().decode(AppRule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(json.scratchpad, 3)

        var export = SettingsExport.defaults()
        export.appRules = [rule]
        let data = try SettingsTOMLCodec.encode(export)
        let toml = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(toml.contains("scratchpad = 3"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).appRules.first?.scratchpad, 3)
    }

    func testValidScratchpadRequiresRangeAndNoConflict() {
        let slots = ScratchpadIndex.range
        for slot in [slots.lowerBound, slots.upperBound] {
            XCTAssertEqual(AppRule(bundleId: "a", scratchpad: slot).validScratchpad?.rawValue, slot)
        }
        for slot in [slots.lowerBound - 1, slots.upperBound + 1] {
            XCTAssertNil(AppRule(bundleId: "a", scratchpad: slot).validScratchpad)
        }
        XCTAssertNil(AppRule(bundleId: "a", assignToWorkspace: "2", scratchpad: 2).validScratchpad)
        XCTAssertNil(AppRule(bundleId: "a", layout: .tile, scratchpad: 2).validScratchpad)
        XCTAssertEqual(AppRule(bundleId: "a", layout: .float, scratchpad: 2).validScratchpad, 2)
    }

    func testScratchpadConflict() {
        XCTAssertNil(AppRule(bundleId: "a").scratchpadConflict)
        XCTAssertNil(AppRule(bundleId: "a", scratchpad: 2).scratchpadConflict)
        XCTAssertEqual(
            AppRule(bundleId: "a", assignToWorkspace: "2", scratchpad: 2).scratchpadConflict,
            .assignToWorkspace
        )
        XCTAssertEqual(
            AppRule(bundleId: "a", layout: .tile, assignToWorkspace: "2", scratchpad: 2).scratchpadConflict,
            .assignToWorkspace
        )
        XCTAssertEqual(AppRule(bundleId: "a", layout: .tile, scratchpad: 2).scratchpadConflict, .tileLayout)
        XCTAssertNil(AppRule(bundleId: "a", layout: .tile).scratchpadConflict)
    }

    func testWhitespaceWorkspaceDoesNotConflictWithScratchpad() {
        let rule = AppRule(bundleId: "a", assignToWorkspace: "  ", scratchpad: 2)
        XCTAssertNil(rule.scratchpadConflict)
        XCTAssertEqual(rule.validScratchpad, 2)
        XCTAssertNil(AppRuleDraftValidation.scratchpadError(for: rule))
    }

    func testScratchpadEffectCountsOnlyWhenValid() {
        XCTAssertTrue(AppRule(bundleId: "a", scratchpad: 2).hasEffect)
        let outOfRange = AppRule(bundleId: "a", scratchpad: ScratchpadIndex.range.upperBound + 1)
        XCTAssertFalse(outOfRange.hasEffect)
        XCTAssertTrue(outOfRange.hasAnyRule)
    }

    func testInitialContainerPrimarySpanRoundTripsThroughTOML() throws {
        var export = SettingsExport.defaults()
        export.appRules = [AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: 0.5)]

        let data = try SettingsTOMLCodec.encode(export)
        let toml = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(toml.contains("initialContainerPrimarySpan = 0.5"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).appRules.first?.initialContainerPrimarySpan, 0.5)
    }

    func testNilInitialContainerPrimarySpanIsOmittedFromJSONAndTOML() throws {
        let rule = AppRule(bundleId: "com.test.app", layout: .float)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any]
        )
        XCTAssertNil(json["initialContainerPrimarySpan"])

        var export = SettingsExport.defaults()
        export.appRules = [rule]
        let tomlData = try SettingsTOMLCodec.encode(export)
        let toml = try XCTUnwrap(String(data: tomlData, encoding: .utf8))
        XCTAssertFalse(toml.contains("initialContainerPrimarySpan"))
        XCTAssertNil(try SettingsTOMLCodec.decode(tomlData).appRules.first?.initialContainerPrimarySpan)
    }

    func testLegacyInitialColumnWidthTOMLKeyIsIgnoredAndDiagnosed() throws {
        var export = SettingsExport.defaults()
        export.appRules = [
            AppRule(
                bundleId: "com.test.app",
                layout: .float,
                initialContainerPrimarySpan: 0.5
            )
        ]
        let canonical = String(decoding: try SettingsTOMLCodec.encode(export), as: UTF8.self)
        let legacy = Data(
            canonical.replacingOccurrences(
                of: "initialContainerPrimarySpan",
                with: "initialColumnWidth"
            ).utf8
        )

        let decoded = try SettingsTOMLCodec.decode(legacy)

        XCTAssertNil(decoded.appRules.first?.initialContainerPrimarySpan)
        XCTAssertEqual(
            SettingsTOMLCodec.unknownKeyPaths(in: legacy),
            ["appRules[0].initialColumnWidth"]
        )
    }

    @MainActor
    func testAppRulesRevisionChangesOnlyForDistinctRules() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMRuleRevision-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
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
        let baseline = settings.appRulesRevision
        let rules = [AppRule(bundleId: "com.test.app", layout: .float)]

        settings.appRules = rules
        XCTAssertEqual(settings.appRulesRevision, baseline + 1)

        settings.appRules = rules
        XCTAssertEqual(settings.appRulesRevision, baseline + 1)
    }

    @MainActor
    func testIPCProjectionRoundTripsInitialContainerPrimarySpan() {
        let rule = AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: 0.5)
        let definition = IPCRuleProjection.definition(from: rule)
        let projectedRule = IPCRuleProjection.appRule(from: definition, id: rule.id)
        let snapshot = IPCRuleProjection.snapshot(
            from: projectedRule,
            position: 1,
            invalidRegexMessagesByRuleId: [:]
        )

        XCTAssertEqual(definition.initialContainerPrimarySpan, 0.5)
        XCTAssertEqual(projectedRule, rule)
        XCTAssertEqual(snapshot.initialContainerPrimarySpan, 0.5)
        XCTAssertTrue(snapshot.isValid)
    }

    @MainActor
    func testIPCProjectionReportsInvalidInitialContainerPrimarySpan() {
        let rule = AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: 1.001)
        let snapshot = IPCRuleProjection.snapshot(
            from: rule,
            position: 1,
            invalidRegexMessagesByRuleId: [:]
        )

        XCTAssertFalse(snapshot.isValid)
        XCTAssertTrue(snapshot.validationMessages.contains { $0.hasPrefix("Initial container primary span") })
    }

    @MainActor
    func testIPCProjectionRoundTripsScratchpad() {
        let rule = AppRule(bundleId: "com.test.app", scratchpad: 4)
        let definition = IPCRuleProjection.definition(from: rule)
        let projectedRule = IPCRuleProjection.appRule(from: definition, id: rule.id)
        let snapshot = IPCRuleProjection.snapshot(
            from: projectedRule,
            position: 1,
            invalidRegexMessagesByRuleId: [:]
        )

        XCTAssertEqual(definition.scratchpad, 4)
        XCTAssertEqual(projectedRule, rule)
        XCTAssertEqual(snapshot.scratchpad, 4)
        XCTAssertTrue(snapshot.isValid)
    }

    @MainActor
    func testIPCProjectionReportsTOMLLoadedInvalidScratchpadWithRawValue() throws {
        let cases: [(rule: AppRule, message: String)] = [
            (
                AppRule(bundleId: "com.test.app", scratchpad: ScratchpadIndex.range.upperBound + 1),
                "Scratchpad must be a slot from 1 to 10"
            ),
            (
                AppRule(bundleId: "com.test.app", assignToWorkspace: "2", scratchpad: 3),
                "Choose a scratchpad or a workspace, not both"
            ),
            (
                AppRule(bundleId: "com.test.app", layout: .tile, scratchpad: 3),
                "Scratchpad windows float, so the layout can't be Tile"
            )
        ]
        for testCase in cases {
            var export = SettingsExport.defaults()
            export.appRules = [testCase.rule]
            let loaded = try XCTUnwrap(
                SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export)).appRules.first
            )

            let snapshot = IPCRuleProjection.snapshot(from: loaded, position: 1, invalidRegexMessagesByRuleId: [:])

            XCTAssertEqual(snapshot.scratchpad, testCase.rule.scratchpad)
            XCTAssertFalse(snapshot.isValid)
            XCTAssertTrue(snapshot.validationMessages.contains(testCase.message), testCase.message)
        }
    }

    func testDraftDefaultsAndRoundTripsInitialContainerPrimarySpan() {
        let emptyDraft = AppRuleDraft()
        XCTAssertFalse(emptyDraft.initialContainerPrimarySpanEnabled)
        XCTAssertEqual(emptyDraft.initialContainerPrimarySpan, 0.5)

        let rule = AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: 0.75)
        let draft = AppRuleDraft(rule: rule)
        XCTAssertTrue(draft.initialContainerPrimarySpanEnabled)
        XCTAssertEqual(draft.initialContainerPrimarySpan, 0.75)
        XCTAssertNil(draft.initialContainerPrimarySpanError)
        XCTAssertEqual(draft.makeRule(), rule)
    }

    func testSelectingBundledApplicationReplacesOnlyApplicationIdentityMatchers() {
        var draft = populatedDraft()
        let expectedId = draft.id

        draft.selectApplication(bundleId: "com.example.Bundled", appName: "Bundled")

        XCTAssertEqual(draft.id, expectedId)
        XCTAssertEqual(draft.bundleId, "com.example.Bundled")
        XCTAssertFalse(draft.appNameMatcherEnabled)
        XCTAssertEqual(draft.appNameSubstring, "")
        assertUnrelatedSelectionState(draft)
    }

    func testSelectingBundlelessApplicationReplacesOnlyApplicationIdentityMatchers() {
        var draft = populatedDraft()
        let expectedId = draft.id

        draft.selectApplication(bundleId: nil, appName: "Bundleless")

        XCTAssertEqual(draft.id, expectedId)
        XCTAssertEqual(draft.bundleId, "")
        XCTAssertTrue(draft.appNameMatcherEnabled)
        XCTAssertEqual(draft.appNameSubstring, "Bundleless")
        assertUnrelatedSelectionState(draft)
    }

    func testInitialContainerPrimarySpanPercentConversionHandlesFractionsAndExtremeValues() {
        let proportion = 0.5555
        let percent = AppRulePrimarySpanPercent.percent(from: proportion)
        XCTAssertEqual(percent, 55.55)
        XCTAssertEqual(
            AppRulePrimarySpanPercent.proportion(from: percent),
            proportion
        )
        XCTAssertTrue(AppRulePrimarySpanPercent.percent(from: .greatestFiniteMagnitude).isInfinite)
        XCTAssertTrue(AppRulePrimarySpanPercent.percent(from: .nan).isNaN)
        XCTAssertEqual(AppRulePrimarySpanPercent.percent(from: .infinity), .infinity)
        XCTAssertEqual(AppRulePrimarySpanPercent.percent(from: -.infinity), -.infinity)
        XCTAssertEqual(
            AppRulePrimarySpanPercent.displayText(for: proportion, locale: Locale(identifier: "en_US_POSIX")),
            "55.55"
        )

        var invalidDraft = AppRuleDraft(bundleId: "com.test.app")
        invalidDraft.initialContainerPrimarySpanEnabled = true
        invalidDraft.initialContainerPrimarySpan = AppRulePrimarySpanPercent.proportion(from: 4.9)
        XCTAssertEqual(invalidDraft.initialContainerPrimarySpan, 0.049)
        XCTAssertNotNil(invalidDraft.initialContainerPrimarySpanError)
    }

    func testDraftEqualityAndRuleRepresentationAreNaNStable() {
        let rule = AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: .nan)
        let lhs = AppRuleDraft(rule: rule)
        let rhs = AppRuleDraft(rule: rule)

        XCTAssertEqual(lhs, rhs)
        XCTAssertTrue(lhs.represents(rule))

        var changed = lhs
        changed.initialContainerPrimarySpan = .infinity
        XCTAssertNotEqual(changed, rhs)
        XCTAssertFalse(changed.represents(rule))
    }

    func testDraftDefaultsAndRoundTripsScratchpad() {
        let emptyDraft = AppRuleDraft()
        XCTAssertFalse(emptyDraft.scratchpadEnabled)
        XCTAssertEqual(emptyDraft.scratchpad, 1)
        XCTAssertNil(emptyDraft.makeRule().scratchpad)

        let rule = AppRule(bundleId: "com.test.app", scratchpad: 4)
        let draft = AppRuleDraft(rule: rule)
        XCTAssertTrue(draft.scratchpadEnabled)
        XCTAssertEqual(draft.scratchpad, 4)
        XCTAssertEqual(draft.makeRule(), rule)
        XCTAssertTrue(draft.represents(rule))
    }

    func testDisabledDraftScratchpadIsOmittedFromRule() {
        var draft = AppRuleDraft(rule: AppRule(bundleId: "com.test.app", scratchpad: 4))
        draft.scratchpadEnabled = false

        XCTAssertNil(draft.makeRule().scratchpad)
        XCTAssertNotEqual(draft, AppRuleDraft(rule: AppRule(bundleId: "com.test.app", scratchpad: 4)))
    }

    func testScratchpadOnlyDraftIsValid() {
        var draft = AppRuleDraft(bundleId: "com.test.app")
        draft.scratchpadEnabled = true
        draft.scratchpad = ScratchpadIndex.range.upperBound

        XCTAssertNil(draft.scratchpadError)
        XCTAssertNil(draft.effectHint)
        XCTAssertTrue(draft.isValid)
    }

    func testDraftScratchpadWithWorkspaceIsInvalid() {
        var draft = AppRuleDraft(bundleId: "com.test.app")
        draft.scratchpadEnabled = true
        draft.scratchpad = 2
        draft.assignToWorkspaceEnabled = true
        draft.assignToWorkspace = "3"

        XCTAssertEqual(draft.scratchpadError, "Choose a scratchpad or a workspace, not both")
        XCTAssertFalse(draft.isValid)
    }

    func testDraftScratchpadWithTileLayoutIsInvalid() {
        var draft = AppRuleDraft(bundleId: "com.test.app")
        draft.scratchpadEnabled = true
        draft.scratchpad = 2
        draft.layoutAction = .tile

        XCTAssertEqual(draft.scratchpadError, "Scratchpad windows float, so the layout can't be Tile")
        XCTAssertFalse(draft.isValid)

        draft.layoutAction = .float
        XCTAssertNil(draft.scratchpadError)
        XCTAssertTrue(draft.isValid)
    }

    func testDraftScratchpadOutsideSlotRangeIsInvalid() {
        for value in [0, 11] {
            var draft = AppRuleDraft(rule: AppRule(bundleId: "com.test.app", scratchpad: value))
            XCTAssertEqual(draft.scratchpadError, "Scratchpad must be a slot from 1 to 10")
            XCTAssertFalse(draft.isValid)

            draft.scratchpadEnabled = false
            XCTAssertNil(draft.scratchpadError)
        }
    }

    private func populatedDraft() -> AppRuleDraft {
        var draft = AppRuleDraft(bundleId: "com.example.Previous")
        draft.layoutAction = .float
        draft.assignToWorkspaceEnabled = true
        draft.assignToWorkspace = "work"
        draft.initialContainerPrimarySpanEnabled = true
        draft.initialContainerPrimarySpan = 0.7
        draft.minWidthEnabled = true
        draft.minWidth = 640
        draft.minHeightEnabled = true
        draft.minHeight = 480
        draft.appNameMatcherEnabled = true
        draft.appNameSubstring = "Previous"
        draft.titleMatcherMode = .regex
        draft.titleSubstring = "unchanged substring"
        draft.titleRegex = "^Document"
        draft.axRoleEnabled = true
        draft.axRole = "AXWindow"
        draft.axSubroleEnabled = true
        draft.axSubrole = "AXStandardWindow"
        return draft
    }

    private func assertUnrelatedSelectionState(_ draft: AppRuleDraft) {
        XCTAssertEqual(draft.layoutAction, .float)
        XCTAssertTrue(draft.assignToWorkspaceEnabled)
        XCTAssertEqual(draft.assignToWorkspace, "work")
        XCTAssertTrue(draft.initialContainerPrimarySpanEnabled)
        XCTAssertEqual(draft.initialContainerPrimarySpan, 0.7)
        XCTAssertTrue(draft.minWidthEnabled)
        XCTAssertEqual(draft.minWidth, 640)
        XCTAssertTrue(draft.minHeightEnabled)
        XCTAssertEqual(draft.minHeight, 480)
        XCTAssertEqual(draft.titleMatcherMode, .regex)
        XCTAssertEqual(draft.titleSubstring, "unchanged substring")
        XCTAssertEqual(draft.titleRegex, "^Document")
        XCTAssertTrue(draft.axRoleEnabled)
        XCTAssertEqual(draft.axRole, "AXWindow")
        XCTAssertTrue(draft.axSubroleEnabled)
        XCTAssertEqual(draft.axSubrole, "AXStandardWindow")
    }
}
