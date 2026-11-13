// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class WindowRuleEngineTests: XCTestCase {
    private let pictureInPictureBrowsers: [(bundleId: String, title: String)] = [
        ("org.mozilla.firefox", "Picture-in-Picture"),
        ("app.zen-browser.zen", "Picture-in-Picture"),
        ("net.librewolf.librewolf", "Picture-in-Picture"),
        ("com.google.Chrome", "Picture-in-picture"),
        ("com.brave.Browser", "Picture-in-picture"),
        ("com.microsoft.edgemac", "Picture in Picture")
    ]

    private func facts(
        appName: String?,
        bundleId: String?,
        title: String? = nil,
        role: String? = kAXWindowRole as String,
        subrole: String? = kAXStandardWindowSubrole as String,
        hasCloseButton: Bool = true,
        hasFullscreenButton: Bool = true,
        hasZoomButton: Bool = true,
        hasMinimizeButton: Bool = true,
        windowServer: WindowServerInfo? = nil,
        attributeFetchSucceeded: Bool = true,
        isMain: Bool? = false,
        isModal: Bool? = false
    ) -> WindowRuleFacts {
        WindowRuleFacts(
            appName: appName,
            ax: AXWindowFacts(
                role: role,
                subrole: subrole,
                title: title,
                hasCloseButton: hasCloseButton,
                hasFullscreenButton: hasFullscreenButton,
                fullscreenButtonEnabled: hasFullscreenButton,
                hasZoomButton: hasZoomButton,
                hasMinimizeButton: hasMinimizeButton,
                appPolicy: .regular,
                bundleId: bundleId,
                attributeFetchSucceeded: attributeFetchSucceeded,
                isMain: isMain,
                isModal: isModal
            ),
            sizeConstraints: nil,
            windowServer: windowServer
        )
    }

    private func evaluate(
        _ engine: WindowRuleEngine,
        _ facts: WindowRuleFacts,
        token: WindowToken? = nil,
        appFullscreen: Bool = false
    ) -> WindowDecision {
        engine.decision(for: facts, token: token, appFullscreen: appFullscreen)
    }

    private func transientFacts(
        bundleId: String,
        windowServer: WindowServerInfo?,
        title: String? = nil,
        role: String? = kAXWindowRole as String,
        subrole: String? = kAXUnknownSubrole as String,
        hasCloseButton: Bool = false,
        hasFullscreenButton: Bool = false,
        hasZoomButton: Bool = false,
        hasMinimizeButton: Bool = false,
        isMain: Bool? = false,
        isModal: Bool? = false
    ) -> WindowRuleFacts {
        facts(
            appName: "Widget Host",
            bundleId: bundleId,
            title: title,
            role: role,
            subrole: subrole,
            hasCloseButton: hasCloseButton,
            hasFullscreenButton: hasFullscreenButton,
            hasZoomButton: hasZoomButton,
            hasMinimizeButton: hasMinimizeButton,
            windowServer: windowServer,
            isMain: isMain,
            isModal: isModal
        )
    }

    private func transientWindowServerInfo(
        token: WindowToken,
        frame: CGRect = .zero,
        level: Int32 = 0,
        tags: UInt64 = 0x1_400C_2482,
        attributes: UInt32 = 3,
        parentId: UInt32 = 7_905
    ) -> WindowServerInfo {
        WindowServerInfo(
            id: UInt32(token.windowId),
            pid: Int32(token.pid),
            level: level,
            frame: frame,
            tags: tags,
            attributes: attributes,
            parentId: parentId
        )
    }

    func testAppNameWildcardMatchesNoBundleWindows() {
        let engine = WindowRuleEngine()
        let rule = AppRule(bundleId: "", appNameSubstring: "VMD", layout: .float)
        engine.rebuild(rules: [rule])

        for title in ["VMD Main", "VMD TkConsole"] {
            let decision = evaluate(engine, facts(appName: "VMD", bundleId: nil, title: title))
            XCTAssertEqual(decision.disposition, .floating)
            XCTAssertEqual(decision.source, .userRule(rule.id))
        }

        let other = evaluate(engine, facts(appName: "Finder", bundleId: nil))
        XCTAssertNotEqual(other.source, .userRule(rule.id))
    }

    func testAppNamePlusTitleTargetsSingleWindow() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            bundleId: "",
            appNameSubstring: "VMD",
            titleSubstring: "TkConsole",
            layout: .float
        )
        engine.rebuild(rules: [rule])

        let tkConsole = evaluate(engine, facts(appName: "VMD", bundleId: nil, title: "VMD TkConsole"))
        XCTAssertEqual(tkConsole.source, .userRule(rule.id))

        let main = evaluate(engine, facts(appName: "VMD", bundleId: nil, title: "VMD Main"))
        XCTAssertNotEqual(main.source, .userRule(rule.id))
    }

    func testBundledAxSubroleRefinesMatch() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            bundleId: "com.test.app",
            axSubrole: kAXStandardWindowSubrole as String,
            layout: .float
        )
        engine.rebuild(rules: [rule])

        let matched = evaluate(engine, facts(appName: "Test", bundleId: "com.test.app"))
        XCTAssertEqual(matched.disposition, .floating)
        XCTAssertEqual(matched.source, .userRule(rule.id))

        let wrongSubrole = evaluate(
            engine,
            facts(appName: "Test", bundleId: "com.test.app", subrole: "AXDialog")
        )
        XCTAssertNotEqual(wrongSubrole.source, .userRule(rule.id))
    }

    func testUnanchoredRuntimeRulesAreDropped() {
        let cases: [(label: String, rule: AppRule, facts: WindowRuleFacts)] = [
            ("action only", AppRule(bundleId: "", layout: .float), facts(appName: "Anything", bundleId: nil)),
            (
                "AX subrole only",
                AppRule(bundleId: "", axSubrole: kAXStandardWindowSubrole as String, layout: .float),
                facts(appName: "VMD", bundleId: nil, title: "VMD Main")
            )
        ]
        for row in cases {
            let engine = WindowRuleEngine()
            engine.rebuild(rules: [row.rule])
            let decision = evaluate(engine, row.facts)
            XCTAssertNotEqual(decision.source, .userRule(row.rule.id), row.label)
        }
    }

    func testBundledRuleDoesNotMatchNoBundleWindow() {
        let engine = WindowRuleEngine()
        let rule = AppRule(bundleId: "com.test.app", layout: .float)
        engine.rebuild(rules: [rule])

        let decision = evaluate(engine, facts(appName: "Test", bundleId: nil))
        XCTAssertNotEqual(decision.source, .userRule(rule.id))
    }

    func testBundleRuleOutranksSingleMatcherWildcard() {
        let engine = WindowRuleEngine()
        let wildcard = AppRule(bundleId: "", appNameSubstring: "Test", layout: .float)
        let bundled = AppRule(bundleId: "com.test.app", layout: .tile)
        engine.rebuild(rules: [wildcard, bundled])

        let decision = evaluate(engine, facts(appName: "Test App", bundleId: "com.test.app"))
        XCTAssertEqual(decision.disposition, .managed)
        XCTAssertEqual(decision.source, .userRule(bundled.id))
    }

    func testSteamBuiltInDefersWhenAXFactsFailed() {
        let engine = WindowRuleEngine()
        let decision = evaluate(
            engine,
            facts(
                appName: "Steam",
                bundleId: "com.valvesoftware.steam",
                role: nil,
                subrole: nil,
                attributeFetchSucceeded: false
            )
        )

        XCTAssertEqual(decision.disposition, .undecided)
        XCTAssertEqual(decision.deferredReason, .attributeFetchFailed)
        XCTAssertEqual(decision.admissionOutcome, .deferred)
    }

    func testSteamBuiltInTilesWhenAXFactsAreValid() {
        let engine = WindowRuleEngine()
        let decision = evaluate(
            engine,
            facts(appName: "Steam", bundleId: "com.valvesoftware.steam.helper")
        )

        XCTAssertEqual(decision.disposition, .managed)
        XCTAssertEqual(decision.source, .builtInRule("steamClient"))
    }

    func testSteamBuiltInDoesNotTileTheNonHelperBundle() {
        let engine = WindowRuleEngine()
        let decision = evaluate(
            engine,
            facts(
                appName: "Steam",
                bundleId: "com.valvesoftware.steam",
                subrole: kAXUnknownSubrole as String
            )
        )

        XCTAssertNotEqual(decision.source, .builtInRule("steamClient"))
        XCTAssertEqual(decision.disposition, .unmanaged)
        XCTAssertEqual(decision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
    }

    func testCleanShotRecordingOverlayIsExternalAtSystemWindowLevel() {
        let engine = WindowRuleEngine()
        let token = WindowToken(pid: 84_061, windowId: 84_062)
        let decision = evaluate(
            engine,
            facts(
                appName: "CleanShot X",
                bundleId: "pl.maketheweb.cleanshotx",
                windowServer: WindowServerInfo(
                    id: 84_062,
                    pid: 84_061,
                    level: 103,
                    frame: .zero
                )
            ),
            token: token
        )

        XCTAssertEqual(decision.disposition, .unmanaged)
        XCTAssertEqual(decision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
    }

    func testMoreSpecificRuleInheritsInitialSpanItDoesNotSet() {
        let engine = WindowRuleEngine()
        let generic = AppRule(bundleId: "com.test.app", initialContainerPrimarySpan: 0.5)
        let specific = AppRule(
            bundleId: "com.test.app",
            titleSubstring: "Inspector",
            layout: .tile
        )
        engine.rebuild(rules: [generic, specific])

        let decision = evaluate(
            engine,
            facts(appName: "Test", bundleId: "com.test.app", title: "Inspector")
        )
        XCTAssertEqual(decision.source, .userRule(specific.id))
        XCTAssertEqual(decision.admissionHints.initialNiriContainerPrimarySpan, 0.5)
        XCTAssertEqual(
            decision.ruleProvenance,
            WindowRuleProvenance(layout: specific.id, initialContainerPrimarySpan: generic.id)
        )
    }

    func testDefaultMinimumSizeRuleAndLaterWorkspaceRuleBothApply() {
        let engine = WindowRuleEngine()
        let defaults = BuiltInSettingsDefaults.appRules
        guard let ghostty = defaults.first(where: { $0.bundleId == "com.mitchellh.ghostty" }) else {
            return XCTFail("Missing the default Ghostty rule")
        }
        let workspaceRule = AppRule(bundleId: "com.mitchellh.ghostty", assignToWorkspace: "1")
        engine.rebuild(rules: defaults + [workspaceRule])

        let decision = evaluate(engine, facts(appName: "Ghostty", bundleId: "com.mitchellh.ghostty"))

        XCTAssertEqual(decision.workspaceName, "1")
        XCTAssertEqual(
            decision.ruleEffects,
            ManagedWindowRuleEffects(minWidth: ghostty.minWidth, minHeight: ghostty.minHeight)
        )
        XCTAssertEqual(
            decision.ruleProvenance,
            WindowRuleProvenance(workspace: workspaceRule.id, minWidth: ghostty.id, minHeight: ghostty.id)
        )
    }

    func testEachSettingTakesTheMostSpecificThenEarliestRule() {
        let engine = WindowRuleEngine()
        let early = AppRule(bundleId: "com.test.app", assignToWorkspace: "1", minWidth: 300)
        let late = AppRule(bundleId: "com.test.app", assignToWorkspace: "2", minHeight: 200)
        let specific = AppRule(bundleId: "com.test.app", titleSubstring: "Editor", minWidth: 500)
        engine.rebuild(rules: [early, late, specific])

        let decision = evaluate(engine, facts(appName: "Test", bundleId: "com.test.app", title: "Editor"))

        XCTAssertEqual(decision.source, .userRule(specific.id))
        XCTAssertEqual(decision.workspaceName, "1")
        XCTAssertEqual(decision.ruleEffects, ManagedWindowRuleEffects(minWidth: 500, minHeight: 200))
        XCTAssertEqual(
            decision.ruleProvenance,
            WindowRuleProvenance(workspace: early.id, minWidth: specific.id, minHeight: late.id)
        )
    }

    func testAutomaticRuleTakesLayoutFromAnotherMatchingRule() {
        let engine = WindowRuleEngine()
        let automatic = AppRule(bundleId: "com.test.app", titleSubstring: "Doc", minWidth: 400)
        let floating = AppRule(bundleId: "com.test.app", layout: .float)
        engine.rebuild(rules: [automatic, floating])

        let decision = evaluate(engine, facts(appName: "Test", bundleId: "com.test.app", title: "Doc"))

        XCTAssertEqual(decision.disposition, .floating)
        XCTAssertEqual(decision.layoutDecisionKind, .explicitLayout)
        XCTAssertEqual(decision.source, .userRule(floating.id))
        XCTAssertEqual(decision.ruleEffects.minWidth, 400)
        XCTAssertEqual(decision.ruleProvenance, WindowRuleProvenance(layout: floating.id, minWidth: automatic.id))
    }

    func testTitleScopedRuleJoinsCompositionOnceTheTitleMatches() {
        let engine = WindowRuleEngine()
        let bundleRule = AppRule(bundleId: "com.test.app", assignToWorkspace: "2")
        let titleRule = AppRule(bundleId: "com.test.app", titleSubstring: "Doc", minWidth: 400)
        engine.rebuild(rules: [bundleRule, titleRule])

        let untitled = evaluate(engine, facts(appName: "Test", bundleId: "com.test.app"))
        XCTAssertEqual(untitled.deferredReason, .requiredTitleMissing)
        XCTAssertEqual(untitled.workspaceName, "2")
        XCTAssertNil(untitled.ruleEffects.minWidth)

        let titled = evaluate(engine, facts(appName: "Test", bundleId: "com.test.app", title: "Doc"))
        XCTAssertEqual(titled.workspaceName, "2")
        XCTAssertEqual(titled.ruleEffects.minWidth, 400)
        XCTAssertEqual(titled.ruleProvenance, WindowRuleProvenance(workspace: bundleRule.id, minWidth: titleRule.id))
    }

    func testScratchpadRuleBecomesAdmissionDestination() {
        let engine = WindowRuleEngine()
        let rule = AppRule(bundleId: "com.test.app", scratchpad: 2)
        engine.rebuild(rules: [rule])

        let decision = evaluate(engine, facts(appName: "Test", bundleId: "com.test.app"))

        XCTAssertEqual(decision.admissionHints.scratchpad, 2)
        XCTAssertNil(decision.workspaceName)
        XCTAssertEqual(decision.ruleProvenance, WindowRuleProvenance(scratchpad: rule.id))
    }

    func testWhitespaceWorkspaceDoesNotBlockScratchpadDestination() {
        let engine = WindowRuleEngine()
        let rule = AppRule(bundleId: "com.test.app", assignToWorkspace: "  ", scratchpad: 2)
        engine.rebuild(rules: [rule])

        let decision = evaluate(engine, facts(appName: "Test", bundleId: "com.test.app"))

        XCTAssertEqual(decision.admissionHints.scratchpad, 2)
        XCTAssertNil(decision.workspaceName)
        XCTAssertEqual(decision.ruleProvenance, WindowRuleProvenance(scratchpad: rule.id))
    }

    func testWhitespaceWorkspaceIsNotADestination() {
        let engine = WindowRuleEngine()
        let rule = AppRule(bundleId: "com.test.app", layout: .float, assignToWorkspace: "  ")
        engine.rebuild(rules: [rule])

        let decision = evaluate(engine, facts(appName: "Test", bundleId: "com.test.app"))

        XCTAssertNil(decision.workspaceName)
        XCTAssertNil(decision.ruleProvenance.workspace)
    }

    func testMoreSpecificWorkspaceRuleBeatsScratchpadRule() {
        let engine = WindowRuleEngine()
        let scratchpadRule = AppRule(bundleId: "com.test.app", scratchpad: 2)
        let workspaceRule = AppRule(bundleId: "com.test.app", titleSubstring: "Doc", assignToWorkspace: "3")
        engine.rebuild(rules: [scratchpadRule, workspaceRule])

        let decision = evaluate(engine, facts(appName: "Test", bundleId: "com.test.app", title: "Doc"))

        XCTAssertEqual(decision.workspaceName, "3")
        XCTAssertNil(decision.admissionHints.scratchpad)
        XCTAssertEqual(decision.ruleProvenance, WindowRuleProvenance(workspace: workspaceRule.id))
    }

    func testMoreSpecificScratchpadRuleBeatsWorkspaceRule() {
        let engine = WindowRuleEngine()
        let workspaceRule = AppRule(bundleId: "com.test.app", assignToWorkspace: "3")
        let scratchpadRule = AppRule(bundleId: "com.test.app", titleSubstring: "Doc", scratchpad: 2)
        engine.rebuild(rules: [workspaceRule, scratchpadRule])

        let decision = evaluate(engine, facts(appName: "Test", bundleId: "com.test.app", title: "Doc"))

        XCTAssertEqual(decision.admissionHints.scratchpad, 2)
        XCTAssertNil(decision.workspaceName)
        XCTAssertEqual(decision.ruleProvenance, WindowRuleProvenance(scratchpad: scratchpadRule.id))
    }

    func testRuleSettingScratchpadAndWorkspaceUsesOnlyWorkspace() {
        let engine = WindowRuleEngine()
        let rule = AppRule(bundleId: "com.test.app", assignToWorkspace: "3", scratchpad: 2)
        engine.rebuild(rules: [rule])

        let decision = evaluate(engine, facts(appName: "Test", bundleId: "com.test.app"))

        XCTAssertEqual(decision.workspaceName, "3")
        XCTAssertNil(decision.admissionHints.scratchpad)
        XCTAssertEqual(decision.ruleProvenance, WindowRuleProvenance(workspace: rule.id))
    }

    func testRuleSettingScratchpadAndTileLayoutKeepsOnlyTileLayout() {
        let engine = WindowRuleEngine()
        let rule = AppRule(bundleId: "com.test.app", layout: .tile, scratchpad: 2)
        engine.rebuild(rules: [rule])

        let decision = evaluate(engine, facts(appName: "Test", bundleId: "com.test.app"))

        XCTAssertEqual(decision.disposition, .managed)
        XCTAssertEqual(decision.layoutDecisionKind, .explicitLayout)
        XCTAssertNil(decision.admissionHints.scratchpad)
        XCTAssertEqual(decision.ruleProvenance, WindowRuleProvenance(layout: rule.id))
    }

    func testManualOverrideKeepsScratchpadDestination() {
        let engine = WindowRuleEngine()
        let rule = AppRule(bundleId: "com.test.app", scratchpad: 4)
        engine.rebuild(rules: [rule])

        let decision = WindowRuleEngine.applyingManualOverride(
            evaluate(engine, facts(appName: "Test", bundleId: "com.test.app")),
            manualOverride: .forceTile
        )

        XCTAssertEqual(decision.source, .manualOverride)
        XCTAssertEqual(decision.admissionHints.scratchpad, 4)
        XCTAssertEqual(decision.ruleProvenance, WindowRuleProvenance(scratchpad: rule.id))
    }

    func testManualOverrideKeepsComposedEffectsAndDropsLayoutProvenance() {
        let engine = WindowRuleEngine()
        let floating = AppRule(bundleId: "com.test.app", layout: .float, assignToWorkspace: "2")
        let sized = AppRule(bundleId: "com.test.app", titleSubstring: "Doc", minWidth: 400)
        engine.rebuild(rules: [floating, sized])

        let decision = WindowRuleEngine.applyingManualOverride(
            evaluate(engine, facts(appName: "Test", bundleId: "com.test.app", title: "Doc")),
            manualOverride: .forceTile
        )

        XCTAssertEqual(decision.disposition, .managed)
        XCTAssertEqual(decision.source, .manualOverride)
        XCTAssertEqual(decision.workspaceName, "2")
        XCTAssertEqual(decision.ruleEffects.minWidth, 400)
        XCTAssertEqual(decision.ruleProvenance, WindowRuleProvenance(workspace: floating.id, minWidth: sized.id))
    }

    func testDebugDumpNamesTheRuleBehindEachSetting() {
        let workspaceRuleId = UUID()
        let minWidthRuleId = UUID()
        let scratchpadRuleId = UUID()
        let snapshot = WindowDecisionDebugSnapshot(
            token: nil,
            appName: "Test",
            bundleId: "com.test.app",
            title: nil,
            axRole: nil,
            axSubrole: nil,
            appFullscreen: false,
            manualOverride: nil,
            disposition: .managed,
            source: .userRule(minWidthRuleId),
            layoutDecisionKind: .fallbackLayout,
            deferredReason: nil,
            admissionOutcome: .trackedTiling,
            workspaceName: "2",
            scratchpad: 5,
            minWidth: 400,
            minHeight: nil,
            initialNiriContainerPrimarySpan: nil,
            ruleProvenance: WindowRuleProvenance(
                workspace: workspaceRuleId,
                minWidth: minWidthRuleId,
                scratchpad: scratchpadRuleId
            ),
            heuristicReasons: [],
            attributeFetchSucceeded: true
        )
        let lines = Set(snapshot.formattedDump().split(separator: "\n").map(String.init))

        XCTAssertTrue(lines.contains("workspaceRuleId=\(workspaceRuleId.uuidString)"))
        XCTAssertTrue(lines.contains("scratchpad=5"))
        XCTAssertTrue(lines.contains("scratchpadRuleId=\(scratchpadRuleId.uuidString)"))
        XCTAssertTrue(lines.contains("minWidthRuleId=\(minWidthRuleId.uuidString)"))
        XCTAssertTrue(lines.contains("minHeightRuleId=nil"))
        XCTAssertTrue(lines.contains("layoutRuleId=nil"))
    }

    func testSystemTextInputPanelStaysUnmanagedWithWildcard() {
        let engine = WindowRuleEngine()
        let wildcard = AppRule(bundleId: "", appNameSubstring: "Input", layout: .float)
        engine.rebuild(rules: [wildcard])

        let decision = evaluate(
            engine,
            facts(appName: "Input Agent", bundleId: "com.apple.textinputmenuagent")
        )
        XCTAssertEqual(decision.disposition, .unmanaged)
    }

    func testScopedTitleFetchEnabledForNoBundleTitleRule() {
        let engine = WindowRuleEngine()
        XCTAssertFalse(engine.requiresTitle(for: nil))

        let rule = AppRule(bundleId: "", titleSubstring: "Main", layout: .float)
        engine.rebuild(rules: [rule])

        XCTAssertTrue(engine.requiresTitle(for: nil))
        XCTAssertTrue(engine.requiresTitle(for: "example.app"))

        let decision = evaluate(engine, facts(appName: "VMD", bundleId: nil, title: "VMD Main"))
        XCTAssertEqual(decision.disposition, .floating)
        XCTAssertEqual(decision.source, .userRule(rule.id))
    }

    func testAppNameScopedTitleRuleFetchesOnlyForMatchingApp() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            bundleId: "",
            appNameSubstring: "VMD",
            titleSubstring: "Main",
            layout: .float
        )
        engine.rebuild(rules: [rule])

        XCTAssertTrue(engine.requiresTitle(for: "example.app", appName: "VMD Viewer"))
        XCTAssertFalse(engine.requiresTitle(for: "example.app", appName: "Other App"))
        XCTAssertNotEqual(
            evaluate(engine, facts(appName: "Other App", bundleId: "example.app")).disposition,
            .undecided
        )
    }

    func testTitleFetchAndWindowMatchingShareCombinedAppScope() {
        let engine = WindowRuleEngine()
        let rule = AppRule(
            bundleId: "com.test.editor",
            appNameSubstring: "Editor",
            titleRegex: "^Settings$",
            layout: .float
        )
        engine.rebuild(rules: [rule])
        let cases: [(bundleId: String?, appName: String?, matches: Bool)] = [
            ("com.test.editor", "Editor", true),
            ("COM.TEST.EDITOR", "My EDITOR", true),
            (nil, "Editor", false),
            ("com.test.editor", nil, false),
            ("com.test.other", "Editor", false),
            ("com.test.editor", "Other App", false)
        ]

        for testCase in cases {
            XCTAssertEqual(
                engine.requiresTitle(for: testCase.bundleId, appName: testCase.appName),
                testCase.matches
            )
            let decision = evaluate(
                engine,
                facts(appName: testCase.appName, bundleId: testCase.bundleId, title: "Settings")
            )
            XCTAssertEqual(decision.source == .userRule(rule.id), testCase.matches)
            let withoutTitle = evaluate(engine, facts(appName: testCase.appName, bundleId: testCase.bundleId))
            XCTAssertEqual(withoutTitle.deferredReason == .requiredTitleMissing, testCase.matches)
        }
    }

    func testInvalidCompiledRegexIsExcludedAndClearedOnRebuild() {
        let engine = WindowRuleEngine()
        var rule = AppRule(bundleId: "com.test.editor", titleRegex: "[", layout: .float)
        engine.rebuild(rules: [rule])

        XCTAssertNotNil(engine.invalidRegexMessagesByRuleId[rule.id])
        XCTAssertFalse(engine.requiresTitle(for: rule.bundleId))
        XCTAssertNotEqual(
            evaluate(engine, facts(appName: "Editor", bundleId: rule.bundleId, title: "Settings")).source,
            .userRule(rule.id)
        )

        rule.titleRegex = "^Settings$"
        engine.rebuild(rules: [rule])

        XCTAssertTrue(engine.invalidRegexMessagesByRuleId.isEmpty)
        XCTAssertTrue(engine.requiresTitle(for: rule.bundleId))
        XCTAssertEqual(
            evaluate(engine, facts(appName: "Editor", bundleId: rule.bundleId, title: "Settings")).source,
            .userRule(rule.id)
        )
    }

    func testRuleProjectionValidityMatrix() {
        let cases: [(label: String, rule: AppRule, valid: Bool)] = [
            ("anchored app name", AppRule(bundleId: "", appNameSubstring: "VMD", layout: .float), true),
            ("no anchor", AppRule(bundleId: "", layout: .float), false),
            ("effectless", AppRule(bundleId: "com.test.app", appNameSubstring: "Test"), false)
        ]
        for row in cases {
            let snapshot = IPCRuleProjection.snapshot(from: row.rule, position: 1, invalidRegexMessagesByRuleId: [:])
            XCTAssertEqual(snapshot.isValid, row.valid, row.label)
            XCTAssertEqual(snapshot.validationMessages.isEmpty, row.valid, row.label)
        }
    }

    func testEffectlessRuleDoesNotShadowEffectiveRule() {
        let engine = WindowRuleEngine()
        // More specific (bundle + app name) but effect-less: must be dropped, not shadow.
        let effectless = AppRule(bundleId: "com.test.app", appNameSubstring: "Test")
        // Less specific (bundle only) but floats.
        let effective = AppRule(bundleId: "com.test.app", layout: .float)
        engine.rebuild(rules: [effectless, effective])

        let decision = evaluate(engine, facts(appName: "Test", bundleId: "com.test.app"))
        XCTAssertEqual(decision.disposition, .floating)
        XCTAssertEqual(decision.source, .userRule(effective.id))
    }

    func testParentedSurfacesAreExternalAcrossBundles() {
        let engine = WindowRuleEngine()
        let popupToken = WindowToken(pid: 86_312, windowId: 7_916)
        let dropdownToken = WindowToken(pid: 86_312, windowId: 7_907)
        let traceSamples = [
            (
                popupToken,
                transientWindowServerInfo(
                    token: popupToken,
                    frame: CGRect(x: 2_128, y: 126, width: 320, height: 425)
                )
            ),
            (
                dropdownToken,
                transientWindowServerInfo(
                    token: dropdownToken,
                    frame: CGRect(x: 1_387, y: 71, width: 824, height: 89)
                )
            )
        ]

        for bundleId in ["com.google.Chrome", "org.example.widget-host"] {
            for (token, windowServer) in traceSamples {
                let decision = evaluate(
                    engine,
                    transientFacts(bundleId: bundleId, windowServer: windowServer),
                    token: token
                )
                XCTAssertEqual(decision.disposition, .unmanaged)
                XCTAssertEqual(
                    decision.source,
                    .builtInRule(WindowRuleEngine.externalSurfaceRuleName)
                )
                XCTAssertEqual(decision.admissionOutcome, .ignored)
                XCTAssertEqual(decision.admissionRejectionReason, .externalSurface)
                XCTAssertNil(decision.deferredReason)
            }
        }
    }

    func testMissingOrMismatchedWindowServerEvidenceDefers() {
        let engine = WindowRuleEngine()
        let token = WindowToken(pid: 84_011, windowId: 84_012)
        let mismatchedEvidence = [
            WindowServerInfo(id: 84_013, pid: 84_011, level: 0, frame: .zero, tags: 0x2, parentId: 9),
            WindowServerInfo(id: 84_012, pid: 84_014, level: 0, frame: .zero, tags: 0x2, parentId: 9)
        ]

        for evidence in [nil] + mismatchedEvidence.map(Optional.some) {
            let decision = evaluate(
                engine,
                transientFacts(bundleId: "org.example.widget-host", windowServer: evidence),
                token: token
            )
            XCTAssertEqual(decision.disposition, .undecided)
            XCTAssertEqual(decision.deferredReason, .windowServerEvidenceMissing)
            XCTAssertEqual(decision.admissionPendingReason, .windowServerEvidenceMissing)
            XCTAssertEqual(decision.source, .heuristic)
        }
    }

    func testUnknownSubroleIsExternalRegardlessOfWindowServerTagsOrLevel() {
        let engine = WindowRuleEngine()
        let token = WindowToken(pid: 84_021, windowId: 84_022)
        let nonmatchingEvidence = [
            transientWindowServerInfo(token: token, level: 1),
            transientWindowServerInfo(token: token, parentId: 0),
            transientWindowServerInfo(token: token, parentId: 84_022),
            transientWindowServerInfo(token: token, tags: 0),
            transientWindowServerInfo(token: token, tags: 0x1_400C_2483),
            transientWindowServerInfo(token: token, tags: 0x1_C00C_2482)
        ]

        for evidence in nonmatchingEvidence {
            let decision = evaluate(
                engine,
                transientFacts(bundleId: "org.example.widget-host", windowServer: evidence),
                token: token
            )
            XCTAssertEqual(decision.disposition, .unmanaged)
            XCTAssertEqual(decision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
        }
    }

    func testParentedWindowAndNonWindowRolesRemainExternal() {
        let engine = WindowRuleEngine()
        let token = WindowToken(pid: 84_031, windowId: 84_032)
        let windowServer = transientWindowServerInfo(token: token)
        let candidates = [
            transientFacts(bundleId: "org.example", windowServer: windowServer, role: kAXButtonRole as String),
            transientFacts(
                bundleId: "org.example",
                windowServer: windowServer,
                subrole: kAXStandardWindowSubrole as String
            ),
            transientFacts(bundleId: "org.example", windowServer: windowServer, hasCloseButton: true),
            transientFacts(bundleId: "org.example", windowServer: windowServer, hasFullscreenButton: true),
            transientFacts(bundleId: "org.example", windowServer: windowServer, hasZoomButton: true),
            transientFacts(bundleId: "org.example", windowServer: windowServer, hasMinimizeButton: true)
        ]

        for facts in candidates {
            let decision = evaluate(engine, facts, token: token)
            XCTAssertEqual(decision.disposition, .unmanaged)
            XCTAssertEqual(decision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
        }
    }

    func testParentedDialogsSheetsAndFailedAXFactsAreNeverTracked() {
        let engine = WindowRuleEngine()
        let token = WindowToken(pid: 84_035, windowId: 84_036)
        let windowServer = transientWindowServerInfo(token: token)
        let semanticWindows = [
            transientFacts(
                bundleId: "org.example",
                windowServer: windowServer,
                subrole: kAXDialogSubrole as String
            ),
            transientFacts(
                bundleId: "org.example",
                windowServer: windowServer,
                subrole: kAXSystemDialogSubrole as String
            ),
            transientFacts(
                bundleId: "org.example",
                windowServer: windowServer,
                role: kAXSheetRole as String
            )
        ]

        for facts in semanticWindows {
            let decision = evaluate(engine, facts, token: token)
            XCTAssertEqual(decision.disposition, .unmanaged)
            XCTAssertEqual(decision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
        }

        let failedFacts = facts(
            appName: "Widget Host",
            bundleId: "org.example",
            role: kAXWindowRole as String,
            subrole: kAXUnknownSubrole as String,
            hasCloseButton: false,
            hasFullscreenButton: false,
            hasZoomButton: false,
            hasMinimizeButton: false,
            windowServer: windowServer,
            attributeFetchSucceeded: false
        )
        let failedDecision = evaluate(engine, failedFacts, token: token)
        XCTAssertEqual(failedDecision.disposition, .undecided)
        XCTAssertEqual(failedDecision.deferredReason, .attributeFetchFailed)
    }

    func testParentedSurfacesPrecedeBroadAndPreciseLayoutRules() {
        let token = WindowToken(pid: 84_041, windowId: 84_042)
        let windowServer = transientWindowServerInfo(token: token)

        let userEngine = WindowRuleEngine()
        let broadRule = AppRule(bundleId: "org.example.widget-host", layout: .tile)
        let preciseRule = AppRule(
            bundleId: "org.example.widget-host",
            axRole: kAXWindowRole as String,
            axSubrole: kAXUnknownSubrole as String,
            layout: .tile
        )
        userEngine.rebuild(rules: [broadRule, preciseRule])

        for bundleId in ["org.example.widget-host", "com.valvesoftware.steam.helper"] {
            let decision = evaluate(
                bundleId == "org.example.widget-host" ? userEngine : WindowRuleEngine(),
                transientFacts(bundleId: bundleId, windowServer: windowServer),
                token: token
            )
            XCTAssertEqual(decision.disposition, .unmanaged)
            XCTAssertEqual(decision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
        }
    }

    func testParentedSurfacesPrecedeFullscreenAndPictureInPictureRules() {
        let engine = WindowRuleEngine()
        let token = WindowToken(pid: 84_045, windowId: 84_046)
        let windowServer = transientWindowServerInfo(token: token)
        let fullscreenDecision = evaluate(
            engine,
            transientFacts(bundleId: "org.example.widget-host", windowServer: windowServer),
            token: token,
            appFullscreen: true
        )

        XCTAssertEqual(fullscreenDecision.disposition, .unmanaged)
        XCTAssertEqual(
            fullscreenDecision.source,
            .builtInRule(WindowRuleEngine.externalSurfaceRuleName)
        )

        for browser in pictureInPictureBrowsers {
            let pictureInPictureDecision = evaluate(
                engine,
                transientFacts(
                    bundleId: browser.bundleId,
                    windowServer: windowServer,
                    title: browser.title
                ),
                token: token
            )
            XCTAssertEqual(pictureInPictureDecision.disposition, .unmanaged)
            XCTAssertEqual(
                pictureInPictureDecision.source,
                .builtInRule(WindowRuleEngine.externalSurfaceRuleName)
            )
        }
    }

    func testPictureInPictureDropsUserEffectsWhileMissingTitleDefers() {
        let engine = WindowRuleEngine()
        for browser in pictureInPictureBrowsers {
            let rule = AppRule(
                bundleId: browser.bundleId,
                assignToWorkspace: "2",
                initialContainerPrimarySpan: 0.42,
                minWidth: 420,
                minHeight: 240
            )
            engine.rebuild(rules: [rule])
            let pictureInPicture = evaluate(
                engine,
                facts(appName: "Browser", bundleId: rule.bundleId, title: browser.title),
                appFullscreen: true
            )
            let missingTitle = evaluate(
                engine,
                facts(appName: "Browser", bundleId: rule.bundleId),
                appFullscreen: true
            )

            XCTAssertEqual(pictureInPicture.disposition, .unmanaged)
            XCTAssertEqual(pictureInPicture.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
            XCTAssertEqual(pictureInPicture.layoutDecisionKind, .explicitLayout)
            XCTAssertNil(pictureInPicture.deferredReason)
            XCTAssertNil(pictureInPicture.workspaceName)
            XCTAssertEqual(pictureInPicture.ruleEffects, .none)
            XCTAssertEqual(pictureInPicture.admissionHints, .none)
            XCTAssertEqual(missingTitle.disposition, .undecided)
            XCTAssertEqual(missingTitle.source, .userRule(rule.id))
            XCTAssertEqual(missingTitle.deferredReason, .requiredTitleMissing)
            XCTAssertEqual(missingTitle.workspaceName, "2")
            XCTAssertEqual(missingTitle.ruleEffects, ManagedWindowRuleEffects(
                minWidth: 420,
                minHeight: 240
            ))
            XCTAssertEqual(missingTitle.ruleProvenance, WindowRuleProvenance(
                workspace: rule.id,
                minWidth: rule.id,
                minHeight: rule.id,
                initialContainerPrimarySpan: rule.id
            ))
            XCTAssertEqual(missingTitle.admissionHints.initialNiriContainerPrimarySpan, 0.42)
        }
    }

    func testAutomaticRuleEffectsAndManualOverridesDoNotAdmitExternalSurfaces() {
        let engine = WindowRuleEngine()
        let rule = AppRule(bundleId: "org.example.widget-host", minWidth: 420)
        engine.rebuild(rules: [rule])
        let token = WindowToken(pid: 84_051, windowId: 84_052)
        let windowServer = transientWindowServerInfo(token: token)

        let decision = evaluate(
            engine,
            transientFacts(bundleId: "org.example.widget-host", windowServer: windowServer),
            token: token
        )
        let overridden = WindowRuleEngine.applyingManualOverride(decision, manualOverride: .forceTile)

        XCTAssertEqual(decision.disposition, .unmanaged)
        XCTAssertEqual(decision.ruleEffects, .none)
        XCTAssertEqual(overridden.disposition, .unmanaged)
    }

    func testRootDialogAndFloatingSubrolesRemainManagedFloatingWindows() {
        let engine = WindowRuleEngine()

        for subrole in [kAXDialogSubrole as String, kAXFloatingWindowSubrole as String] {
            let token = WindowToken(pid: 84_061, windowId: subrole == kAXDialogSubrole as String ? 84_062 : 84_063)
            let decision = evaluate(
                engine,
                transientFacts(
                    bundleId: "org.example",
                    windowServer: transientWindowServerInfo(token: token, parentId: 0),
                    subrole: subrole,
                    isModal: true
                ),
                token: token
            )

            XCTAssertEqual(decision.disposition, .floating)
            XCTAssertEqual(decision.source, .heuristic)
        }
    }

    func testFinderQuickLookRemainsExplicitFloatingWindow() {
        let engine = WindowRuleEngine()
        let quickLookToken = WindowToken(pid: 84_064, windowId: 84_065)
        let quickLookDecision = evaluate(
            engine,
            facts(
                appName: "Finder",
                bundleId: "com.apple.finder",
                title: "Quick Look",
                subrole: "Quick Look",
                windowServer: transientWindowServerInfo(token: quickLookToken, parentId: 0)
            ),
            token: quickLookToken
        )

        XCTAssertEqual(quickLookDecision.disposition, .floating)
        XCTAssertEqual(quickLookDecision.source, .builtInRule("finderQuickLook"))
    }

    func testPictureInPictureExclusionPreservesFoundationAnchorMatching() {
        let engine = WindowRuleEngine()
        let token = WindowToken(pid: 84_068, windowId: 84_069)
        for browser in pictureInPictureBrowsers {
            for suffix in ["", "\n", "\r", "\r\n"] {
                let decision = evaluate(
                    engine,
                    facts(
                        appName: "Browser",
                        bundleId: browser.bundleId,
                        title: browser.title + suffix,
                        windowServer: transientWindowServerInfo(token: token, parentId: 0)
                    ),
                    token: token
                )
                XCTAssertEqual(decision.disposition, .unmanaged)
                XCTAssertEqual(decision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
                XCTAssertFalse(decision.tracksWindow)
            }
        }
    }

    func testPictureInPictureExclusionPrecedesUserRulesAndManualOverrides() {
        let engine = WindowRuleEngine()
        for browser in pictureInPictureBrowsers {
            engine.rebuild(rules: [AppRule(
                bundleId: browser.bundleId,
                axRole: kAXWindowRole as String,
                axSubrole: kAXStandardWindowSubrole as String,
                layout: .tile,
                assignToWorkspace: "2",
                minWidth: 500
            )])
            let decision = evaluate(
                engine,
                facts(appName: "Browser", bundleId: browser.bundleId, title: browser.title),
                appFullscreen: true
            )

            XCTAssertEqual(decision.disposition, .unmanaged)
            XCTAssertEqual(decision.admissionOutcome, .ignored)
            XCTAssertNil(decision.workspaceName)
            XCTAssertEqual(decision.ruleEffects, .none)
            XCTAssertEqual(decision.admissionHints, .none)
            for manualOverride in [ManualWindowOverride.forceTile, .forceFloat] {
                XCTAssertEqual(
                    WindowRuleEngine.applyingManualOverride(decision, manualOverride: manualOverride),
                    decision
                )
            }
        }
    }

    func testBrowserTitleReadinessPrecedesExplicitLayoutRules() {
        let engine = WindowRuleEngine()
        for browser in pictureInPictureBrowsers {
            XCTAssertTrue(engine.requiresTitle(for: browser.bundleId))
            XCTAssertTrue(engine.requiresTitle(for: browser.bundleId.uppercased()))
            for layout in [WindowRuleLayoutAction.tile, .float] {
                engine.rebuild(rules: [AppRule(bundleId: browser.bundleId, layout: layout)])
                XCTAssertTrue(engine.requiresTitle(for: browser.bundleId))
                XCTAssertTrue(engine.needsWindowReevaluation)
                let missingTitle = evaluate(engine, facts(appName: "Browser", bundleId: browser.bundleId))
                XCTAssertEqual(missingTitle.disposition, .undecided)
                XCTAssertEqual(missingTitle.deferredReason, .requiredTitleMissing)
                let pictureInPicture = evaluate(
                    engine,
                    facts(appName: "Browser", bundleId: browser.bundleId, title: browser.title)
                )
                XCTAssertEqual(pictureInPicture.disposition, .unmanaged)
                let ordinaryWindow = evaluate(
                    engine,
                    facts(appName: "Browser", bundleId: browser.bundleId, title: "Browser")
                )
                XCTAssertEqual(ordinaryWindow.disposition, layout == .tile ? .managed : .floating)
            }
        }
    }

    func testPictureInPictureExclusionDoesNotDependOnNativeSubrole() {
        let engine = WindowRuleEngine()
        let subroles: [String?] = [
            kAXStandardWindowSubrole as String,
            kAXDialogSubrole as String,
            kAXFloatingWindowSubrole as String,
            nil
        ]
        for browser in pictureInPictureBrowsers {
            for subrole in subroles {
                let decision = evaluate(
                    engine,
                    facts(
                        appName: "Browser",
                        bundleId: browser.bundleId.uppercased(),
                        title: browser.title,
                        subrole: subrole
                    )
                )
                XCTAssertEqual(decision.disposition, .unmanaged)
            }
        }
    }

    func testPictureInPictureExclusionLeavesOtherWindowsManaged() {
        let engine = WindowRuleEngine()
        for browser in pictureInPictureBrowsers {
            for title in ["", "Browser", browser.title + " - Browser"] {
                XCTAssertEqual(
                    evaluate(engine, facts(appName: "Browser", bundleId: browser.bundleId, title: title)).disposition,
                    .managed
                )
            }
        }
    }

    func testPictureInPictureExclusionDoesNotMatchOtherBrowsersOrBrowserFamilyTitles() {
        let engine = WindowRuleEngine()
        XCTAssertFalse(engine.requiresTitle(for: "org.example.browser"))
        for title in ["Picture-in-Picture", "Picture-in-picture", "Picture in Picture"] {
            XCTAssertEqual(
                evaluate(
                    engine,
                    facts(appName: "Other", bundleId: "org.example.browser", title: title)
                ).disposition,
                .managed
            )
            for browser in pictureInPictureBrowsers where browser.title != title {
                XCTAssertEqual(
                    evaluate(engine, facts(appName: "Browser", bundleId: browser.bundleId, title: title)).disposition,
                    .managed
                )
            }
        }
    }

    func testRootNonstandardSurfaceRequiresPreciseRoleAndSubroleRule() {
        let token = WindowToken(pid: 84_071, windowId: 84_072)
        let rootFacts = transientFacts(
            bundleId: "org.example.widget-host",
            windowServer: transientWindowServerInfo(token: token, parentId: 0)
        )
        let broadEngine = WindowRuleEngine()
        broadEngine.rebuild(rules: [AppRule(bundleId: "org.example.widget-host", layout: .float)])
        let broadDecision = evaluate(broadEngine, rootFacts, token: token)

        XCTAssertEqual(broadDecision.disposition, .unmanaged)
        XCTAssertEqual(broadDecision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))

        let preciseEngine = WindowRuleEngine()
        let preciseRule = AppRule(
            bundleId: "org.example.widget-host",
            axRole: kAXWindowRole as String,
            axSubrole: kAXUnknownSubrole as String,
            layout: .float
        )
        preciseEngine.rebuild(rules: [preciseRule])
        let preciseDecision = evaluate(preciseEngine, rootFacts, token: token)

        XCTAssertEqual(preciseDecision.disposition, .floating)
        XCTAssertEqual(preciseDecision.source, .userRule(preciseRule.id))
    }

    func testExplicitInclusionComposesOnlyAmongIncludingRules() {
        let token = WindowToken(pid: 84_073, windowId: 84_074)
        let rootFacts = transientFacts(
            bundleId: "org.example.widget-host",
            windowServer: transientWindowServerInfo(token: token, parentId: 0)
        )
        let broad = AppRule(bundleId: "org.example.widget-host", assignToWorkspace: "3", minWidth: 500)
        let precise = AppRule(
            bundleId: "org.example.widget-host",
            axRole: kAXWindowRole as String,
            axSubrole: kAXUnknownSubrole as String,
            layout: .float
        )
        let engine = WindowRuleEngine()
        engine.rebuild(rules: [broad, precise])
        let decision = evaluate(engine, rootFacts, token: token)

        XCTAssertEqual(decision.disposition, .floating)
        XCTAssertEqual(decision.source, .userRule(precise.id))
        XCTAssertNil(decision.workspaceName)
        XCTAssertEqual(decision.ruleEffects, .none)
        XCTAssertEqual(decision.ruleProvenance, WindowRuleProvenance(layout: precise.id))

        let splitEngine = WindowRuleEngine()
        splitEngine.rebuild(rules: [
            AppRule(
                bundleId: "org.example.widget-host",
                axRole: kAXWindowRole as String,
                axSubrole: kAXUnknownSubrole as String,
                minWidth: 300
            ),
            AppRule(bundleId: "org.example.widget-host", layout: .float)
        ])
        let splitDecision = evaluate(splitEngine, rootFacts, token: token)

        XCTAssertEqual(splitDecision.disposition, .unmanaged)
        XCTAssertEqual(splitDecision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
    }

    func testIncompleteFactsCannotBeAdmittedByRulesOrManualOverrides() {
        let engine = WindowRuleEngine()
        engine.rebuild(rules: [AppRule(bundleId: "org.example", layout: .float)])
        let decision = evaluate(
            engine,
            facts(
                appName: "Example",
                bundleId: "org.example",
                role: nil,
                subrole: nil,
                attributeFetchSucceeded: false
            )
        )
        let overridden = WindowRuleEngine.applyingManualOverride(decision, manualOverride: .forceFloat)

        XCTAssertEqual(decision.disposition, .undecided)
        XCTAssertEqual(decision.deferredReason, .attributeFetchFailed)
        XCTAssertEqual(overridden, decision)
    }

    func testOnlyAXWindowRoleIsAcceptedAsTopLevel() {
        XCTAssertTrue(
            AXWindowService.shouldTreatAsTopLevelWindow(
                role: kAXWindowRole as String,
                subrole: kAXDialogSubrole as String
            )
        )
        XCTAssertFalse(
            AXWindowService.shouldTreatAsTopLevelWindow(
                role: kAXToolbarRole as String,
                subrole: kAXStandardWindowSubrole as String
            )
        )
    }

    func testSystemWindowLevelRequiresPreciseUserInclusion() {
        let token = WindowToken(pid: 84_081, windowId: 84_082)
        let systemLevelFacts = facts(
            appName: "Overlay",
            bundleId: "org.example",
            windowServer: transientWindowServerInfo(
                token: token,
                level: CGWindowLevelForKey(.statusWindow),
                parentId: 0
            )
        )
        let preciseRule = AppRule(
            bundleId: "org.example",
            axRole: kAXWindowRole as String,
            axSubrole: kAXStandardWindowSubrole as String,
            layout: .tile
        )
        let ruleSets = [
            [],
            [AppRule(bundleId: "org.example", layout: .tile)],
            [
                AppRule(
                    bundleId: "org.example",
                    axRole: kAXWindowRole as String,
                    axSubrole: kAXStandardWindowSubrole as String,
                    minWidth: 640
                )
            ]
        ]

        for rules in ruleSets {
            let engine = WindowRuleEngine()
            engine.rebuild(rules: rules)
            let decision = evaluate(engine, systemLevelFacts, token: token)
            XCTAssertEqual(decision.disposition, .unmanaged)
            XCTAssertEqual(decision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
        }

        let preciseEngine = WindowRuleEngine()
        preciseEngine.rebuild(rules: [preciseRule])
        let preciseDecision = evaluate(preciseEngine, systemLevelFacts, token: token)

        XCTAssertEqual(preciseDecision.disposition, .managed)
        XCTAssertEqual(preciseDecision.source, .userRule(preciseRule.id))
    }

    func testSystemWindowLevelRejectsBuiltInsAndParentedSurfaces() {
        let engine = WindowRuleEngine()
        let quickLookToken = WindowToken(pid: 84_083, windowId: 84_084)
        let quickLookDecision = evaluate(
            engine,
            facts(
                appName: "Finder",
                bundleId: "com.apple.finder",
                title: "Quick Look",
                subrole: "Quick Look",
                windowServer: transientWindowServerInfo(
                    token: quickLookToken,
                    level: CGWindowLevelForKey(.statusWindow),
                    parentId: 0
                )
            ),
            token: quickLookToken
        )

        XCTAssertEqual(quickLookDecision.disposition, .unmanaged)
        XCTAssertEqual(quickLookDecision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))

        let parentedToken = WindowToken(pid: 84_085, windowId: 84_086)
        let preciseRule = AppRule(
            bundleId: "org.example",
            axRole: kAXWindowRole as String,
            axSubrole: kAXStandardWindowSubrole as String,
            layout: .float
        )
        let preciseEngine = WindowRuleEngine()
        preciseEngine.rebuild(rules: [preciseRule])
        let parentedDecision = evaluate(
            preciseEngine,
            facts(
                appName: "Overlay",
                bundleId: "org.example",
                windowServer: transientWindowServerInfo(
                    token: parentedToken,
                    level: CGWindowLevelForKey(.statusWindow),
                    parentId: 90_001
                )
            ),
            token: parentedToken
        )

        XCTAssertEqual(parentedDecision.disposition, .unmanaged)
        XCTAssertEqual(parentedDecision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
    }

    func testCloseableAccessoryAppUsesNormalAdmission() {
        let token = WindowToken(pid: 84_091, windowId: 84_092)
        let windowServer = transientWindowServerInfo(token: token, parentId: 0)
        let accessoryFacts = WindowRuleFacts(
            appName: "Accessory",
            ax: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Accessory",
                hasCloseButton: true,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: false,
                hasZoomButton: true,
                hasMinimizeButton: true,
                appPolicy: .accessory,
                bundleId: "org.example.accessory",
                attributeFetchSucceeded: true
            ),
            sizeConstraints: nil,
            windowServer: windowServer
        )
        let decision = evaluate(WindowRuleEngine(), accessoryFacts, token: token)

        XCTAssertEqual(decision.disposition, .floating)
        XCTAssertEqual(decision.source, .heuristic)

        let broadEngine = WindowRuleEngine()
        let broadRule = AppRule(bundleId: "org.example.accessory", layout: .tile)
        broadEngine.rebuild(rules: [broadRule])
        let broadDecision = evaluate(broadEngine, accessoryFacts, token: token)

        XCTAssertEqual(broadDecision.disposition, .managed)
        XCTAssertEqual(broadDecision.source, .userRule(broadRule.id))
    }

    func testButtonlessAccessoryAndProhibitedAppsRequirePreciseSemanticInclusion() {
        let token = WindowToken(pid: 84_093, windowId: 84_094)
        let windowServer = transientWindowServerInfo(token: token, parentId: 0)
        let configurations: [(policy: NSApplication.ActivationPolicy, hasCloseButton: Bool)] = [
            (.accessory, false),
            (.prohibited, false),
            (.prohibited, true)
        ]

        for configuration in configurations {
            let restrictedFacts = WindowRuleFacts(
                appName: "Restricted",
                ax: AXWindowFacts(
                    role: kAXWindowRole as String,
                    subrole: kAXStandardWindowSubrole as String,
                    title: "Restricted",
                    hasCloseButton: configuration.hasCloseButton,
                    hasFullscreenButton: false,
                    fullscreenButtonEnabled: false,
                    hasZoomButton: false,
                    hasMinimizeButton: false,
                    appPolicy: configuration.policy,
                    bundleId: "org.example.restricted",
                    attributeFetchSucceeded: true
                ),
                sizeConstraints: nil,
                windowServer: windowServer
            )
            let broadEngine = WindowRuleEngine()
            broadEngine.rebuild(rules: [AppRule(bundleId: "org.example.restricted", layout: .float)])

            XCTAssertEqual(
                evaluate(broadEngine, restrictedFacts, token: token).source,
                .builtInRule(WindowRuleEngine.externalSurfaceRuleName)
            )

            let preciseEngine = WindowRuleEngine()
            let preciseRule = AppRule(
                bundleId: "org.example.restricted",
                axRole: kAXWindowRole as String,
                axSubrole: kAXStandardWindowSubrole as String,
                layout: .float
            )
            preciseEngine.rebuild(rules: [preciseRule])
            let preciseDecision = evaluate(preciseEngine, restrictedFacts, token: token)

            XCTAssertEqual(preciseDecision.disposition, .floating)
            XCTAssertEqual(preciseDecision.source, .userRule(preciseRule.id))
        }
    }

    func testFootQuakePanelStaysUnmanagedUnderABroadBundleTileRule() {
        let token = WindowToken(pid: 84_101, windowId: 84_102)
        let panelFacts = WindowRuleFacts(
            appName: "foot",
            ax: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: kAXFloatingWindowSubrole as String,
                title: "foot",
                hasCloseButton: false,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: false,
                hasZoomButton: false,
                hasMinimizeButton: false,
                appPolicy: .accessory,
                bundleId: "io.github.gobijan.foot",
                attributeFetchSucceeded: true,
                isMain: true,
                isModal: false
            ),
            sizeConstraints: nil,
            windowServer: transientWindowServerInfo(
                token: token,
                level: CGWindowLevelForKey(.floatingWindow),
                parentId: 0
            )
        )
        let engine = WindowRuleEngine()
        engine.rebuild(rules: [AppRule(bundleId: "io.github.gobijan.foot", layout: .tile)])

        let decision = evaluate(engine, panelFacts, token: token)

        XCTAssertEqual(decision.disposition, .unmanaged)
        XCTAssertEqual(decision.admissionOutcome, .ignored)
        XCTAssertEqual(decision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
        XCTAssertNil(decision.trackedMode)
    }

    func testHelpTagIsHardUnmanagedWithoutWindowServerOrCompleteAXFacts() {
        let engine = WindowRuleEngine()
        let token = WindowToken(pid: 86_312, windowId: 7_918)
        let arbitraryEvidence = [
            nil,
            WindowServerInfo(
                id: 99_999,
                pid: 77_777,
                level: 103,
                frame: CGRect(x: 1_287, y: 1_403, width: 118, height: 22),
                tags: 0x1,
                attributes: 7,
                parentId: 99_999
            )
        ]

        for windowServer in arbitraryEvidence {
            let decision = evaluate(
                engine,
                facts(
                    appName: "Google Chrome",
                    bundleId: "com.google.Chrome",
                    role: kAXHelpTagRole as String,
                    subrole: kAXStandardWindowSubrole as String,
                    windowServer: windowServer,
                    attributeFetchSucceeded: false
                ),
                token: token
            )
            XCTAssertEqual(decision.disposition, .unmanaged)
            XCTAssertEqual(decision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
            XCTAssertEqual(decision.admissionRejectionReason, .externalSurface)
            XCTAssertNil(decision.deferredReason)
        }
    }

    func testHelpTagPrecedesRulesFullscreenAndManualOverrides() {
        let userEngine = WindowRuleEngine()
        let explicitRule = AppRule(
            bundleId: "com.google.Chrome",
            layout: .tile,
            assignToWorkspace: "Web",
            minWidth: 500,
            minHeight: 375
        )
        userEngine.rebuild(rules: [explicitRule])
        let userDecision = evaluate(
            userEngine,
            facts(
                appName: "Google Chrome",
                bundleId: "com.google.Chrome",
                role: kAXHelpTagRole as String,
                subrole: kAXUnknownSubrole as String,
                hasCloseButton: false,
                hasFullscreenButton: false,
                hasZoomButton: false,
                hasMinimizeButton: false
            ),
            appFullscreen: true
        )

        XCTAssertEqual(userDecision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
        XCTAssertEqual(userDecision.disposition, .unmanaged)
        XCTAssertNil(userDecision.workspaceName)
        XCTAssertEqual(userDecision.ruleEffects, .none)

        for override in [ManualWindowOverride.forceTile, .forceFloat] {
            let overridden = WindowRuleEngine.applyingManualOverride(userDecision, manualOverride: override)
            XCTAssertEqual(overridden, userDecision)
        }

        for bundleId in ["com.valvesoftware.steam", "com.apple.textinputmenuagent"] {
            let decision = evaluate(
                WindowRuleEngine(),
                facts(
                    appName: "Help Surface",
                    bundleId: bundleId,
                    role: kAXHelpTagRole as String,
                    subrole: kAXUnknownSubrole as String,
                    hasCloseButton: false,
                    hasFullscreenButton: false,
                    hasZoomButton: false,
                    hasMinimizeButton: false
                )
            )
            XCTAssertEqual(decision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
            XCTAssertEqual(decision.disposition, .unmanaged)
        }

        let titleEngine = WindowRuleEngine()
        titleEngine.rebuild(
            rules: [AppRule(bundleId: "com.google.Chrome", titleSubstring: "Tooltip", layout: .tile)]
        )
        let titleDecision = evaluate(
            titleEngine,
            facts(
                appName: "Google Chrome",
                bundleId: "com.google.Chrome",
                role: kAXHelpTagRole as String,
                subrole: kAXUnknownSubrole as String,
                hasCloseButton: false,
                hasFullscreenButton: false,
                hasZoomButton: false,
                hasMinimizeButton: false
            )
        )
        XCTAssertEqual(titleDecision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
        XCTAssertNil(titleDecision.deferredReason)
    }

    func testParentedHelpTagAndInputMethodShareExternalAdmissionSemantics() {
        let engine = WindowRuleEngine()
        let transientToken = WindowToken(pid: 84_071, windowId: 84_072)
        let transientDecision = evaluate(
            engine,
            transientFacts(
                bundleId: "org.example.widget-host",
                windowServer: transientWindowServerInfo(token: transientToken)
            ),
            token: transientToken
        )
        let helpTagDecision = evaluate(
            engine,
            facts(
                appName: "Widget Host",
                bundleId: "org.example.widget-host",
                role: kAXHelpTagRole as String,
                subrole: kAXUnknownSubrole as String,
                hasCloseButton: false,
                hasFullscreenButton: false,
                hasZoomButton: false,
                hasMinimizeButton: false
            )
        )
        let policyDecision = evaluate(
            engine,
            facts(appName: "Input Agent", bundleId: "com.apple.textinputmenuagent")
        )

        for decision in [transientDecision, helpTagDecision, policyDecision] {
            XCTAssertEqual(decision.disposition, .unmanaged)
            XCTAssertEqual(decision.source, .builtInRule(WindowRuleEngine.externalSurfaceRuleName))
            XCTAssertEqual(decision.layoutDecisionKind, .explicitLayout)
            XCTAssertEqual(decision.admissionOutcome, .ignored)
            XCTAssertEqual(decision.admissionRejectionReason, .externalSurface)
        }
    }
}
