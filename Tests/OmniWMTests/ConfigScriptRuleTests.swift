// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ConfigScriptRuleTests: XCTestCase {
    private let bundle = "com.apple.calculator"

    private func facts(title: String) -> WindowRuleFacts {
        WindowRuleFacts(
            appName: "Calculator",
            ax: AXWindowFacts(
                role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String, title: title,
                hasCloseButton: true, hasFullscreenButton: true, fullscreenButtonEnabled: true,
                hasZoomButton: true, hasMinimizeButton: true, appPolicy: .regular,
                bundleId: bundle, attributeFetchSucceeded: true, isMain: false, isModal: false
            ),
            sizeConstraints: nil,
            windowServer: nil
        )
    }

    func testGUIAndScriptCompileIdenticalRulesAndMakeTheSameAdmissionDecisions() async throws {
        let workspace = "design"
        let titlePattern = "^Plan"
        let width = 640.0
        let base = AppRule(bundleId: bundle, layout: .tile)
        let tie = AppRule(bundleId: bundle, layout: .float, minWidth: width)
        let specific = AppRule(
            bundleId: bundle, titleRegex: titlePattern, layout: .float,
            assignToWorkspace: workspace, assignToWorkspaceForAllWindows: true
        )
        let declarations = """
        local wm = omniwm
        wm.rule { id = '\(tie.id)', bundleId = '\(bundle)', layout = 'float', minWidth = \(width) }
        wm.rule {
            id = '\(specific.id)', bundleId = '\(bundle)', titleRegex = '\(titlePattern)', layout = 'float',
            assignToWorkspace = '\(workspace)', assignToWorkspaceForAllWindows = true,
        }
        """
        let loaded = try await ConfigScriptLoader().evaluate(Data(declarations.utf8), hyperMask: 0)
        var merged = EffectiveAppRules(configured: [base])
        XCTAssertTrue(merged.setScriptRules(loaded.rules.map(\.rule), configured: [base]))

        let gui = WindowRuleEngine(inputMethodBundleIds: [])
        let script = WindowRuleEngine(inputMethodBundleIds: [])
        gui.rebuild(rules: [base, tie, specific])
        script.rebuild(rules: merged.effective)
        XCTAssertEqual(script.compiledUserRules.map(\.rule), gui.compiledUserRules.map(\.rule))
        XCTAssertEqual(script.compiledUserRules.map(\.order), gui.compiledUserRules.map(\.order))
        XCTAssertEqual(
            script.compiledUserRules.map { $0.titleRegex?.pattern },
            gui.compiledUserRules.map { $0.titleRegex?.pattern }
        )
        XCTAssertEqual(
            script.compiledUserRules.map { $0.titleRegex?.options },
            gui.compiledUserRules.map { $0.titleRegex?.options }
        )
        for row in script.compiledUserRules + gui.compiledUserRules {
            if case .builtIn = row.source { XCTFail("User rule compiled as built-in: \(row.rule.id)") }
        }

        let ordinary = facts(title: "Calculator")
        let matching = facts(title: "Plan 1")
        for window in [ordinary, matching] {
            XCTAssertEqual(
                script.decision(for: window, token: nil, appFullscreen: false),
                gui.decision(for: window, token: nil, appFullscreen: false)
            )
        }
        let tiled = script.decision(for: ordinary, token: nil, appFullscreen: false)
        XCTAssertEqual(tiled.disposition, .managed)
        XCTAssertEqual(tiled.ruleProvenance.layout, base.id)
        XCTAssertEqual(tiled.ruleProvenance.minWidth, tie.id)
        XCTAssertEqual(tiled.ruleEffects.minWidth, width)
        let floating = script.decision(for: matching, token: nil, appFullscreen: false)
        XCTAssertEqual(floating.disposition, .floating)
        XCTAssertEqual(floating.ruleProvenance.layout, specific.id)
        XCTAssertEqual(floating.workspaceName, workspace)
        XCTAssertTrue(floating.assignToWorkspaceForAllWindows)
        script.rebuild(rules: [])
        XCTAssertEqual(
            script.decision(for: ordinary, token: nil, appFullscreen: false).source,
            .builtInRule("defaultFloatingApp")
        )
    }

    func testScriptRulesStayInMemoryAndReturnWhenConflictingGUIRuleIsRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = SettingsFilePersistence(directory: root, startWatching: false, deferSaves: false)
        let settings = SettingsStore(persistence: persistence, runtimeState: RuntimeStateStore(directory: root))
        let base = AppRule(bundleId: "com.apple.TextEdit", layout: .tile)
        let overlay = AppRule(bundleId: bundle, layout: .tile)
        var collision = overlay
        collision.layout = .float
        func writeRules(_ rules: [AppRule]) throws {
            var configured = settings.toExport()
            configured.appRules = rules
            try SettingsLuauDocument.initialSource(configured).write(to: persistence.fileURL, options: .atomic)
            persistence.handlePossibleSettingsFileChange()
        }
        try writeRules([base])
        let initial = settings.appRulesRevision
        XCTAssertTrue(settings.setScriptAppRules([overlay]))
        XCTAssertEqual(settings.appRulesRevision, initial + 1)
        XCTAssertFalse(settings.setScriptAppRules([overlay]))
        XCTAssertEqual(settings.effectiveAppRules, [base, overlay])

        try writeRules([base, collision])
        XCTAssertEqual(settings.appRulesDiagnosticSnapshot.rules, [base, collision])
        let masked = settings.appRulesRevision
        XCTAssertEqual(masked, initial + 2)
        XCTAssertEqual(settings.effectiveAppRules, [base, collision])
        XCTAssertFalse(settings.setScriptAppRules([]))
        XCTAssertFalse(settings.setScriptAppRules([overlay]))
        XCTAssertEqual(settings.appRulesRevision, masked)
        settings.gaps.size += 1
        XCTAssertNil(settings.configNotice)
        let persisted = try SettingsLuauDocument(Data(contentsOf: settings.settingsFileURL)).export
        XCTAssertEqual(persisted.appRules, [base, collision])

        try writeRules([base])
        XCTAssertEqual(settings.appRulesRevision, masked + 1)
        XCTAssertEqual(settings.effectiveAppRules, [base, overlay])
        XCTAssertEqual(settings.appRulesDiagnosticSnapshot.rules, [base, overlay])
        settings.gaps.size += 1
        XCTAssertNil(settings.configNotice)
        let unmasked = try SettingsLuauDocument(Data(contentsOf: settings.settingsFileURL)).export
        XCTAssertEqual(unmasked.appRules, [base])
    }

    func testAcceptedChangedGenerationRebuildsAndRequestsRescanExactlyOnce() async throws {
        let wm = WindowAdmissionTestSupport.controller()
        let settings = wm.settings
        let directory = settings.settingsFileURL.deletingLastPathComponent()
        let file = directory.appendingPathComponent("init.luau")
        let refresh = wm.layoutRefreshController
        refresh.suspendForLockScreen()
        refresh.beginPerformanceCapture()
        defer {
            wm.stopConfigScript()
            refresh.resetState()
            _ = refresh.endPerformanceCapture()
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        }
        settings.appRules = []
        let preBootstrap = wm.windowRuleEngine.rebuildCount
        func assertUpdates(_ updates: UInt64, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(wm.windowRuleEngine.rebuildCount, preBootstrap + updates, file: file, line: line)
            XCTAssertEqual(refresh.performanceSnapshot()?.refreshesEnqueued, updates, file: file, line: line)
        }
        let explicitUpdates: UInt64 = 2
        for call in 1 ... explicitUpdates {
            wm.updateAppRules()
            assertUpdates(call)
        }

        let id = UUID()
        func declaration(_ layout: String) -> String {
            "omniwm.rule { id = '\(id)', bundleId = '\(bundle)', layout = '\(layout)' }"
        }
        func write(_ content: String) throws {
            try Data(content.utf8).write(to: file, options: .atomic)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(declaration("tile"))
        wm.startConfigScript(at: file)
        let script = try XCTUnwrap(wm.configScript)
        let started = expectation(description: "Initial rule generation processed")
        script.onReloadProcessed = { started.fulfill() }
        await fulfillment(of: [started], timeout: failureBound)
        script.onReloadProcessed = nil
        func processed(_ edit: () throws -> Void) async throws {
            let done = expectation(description: "Config generation processed")
            done.assertForOverFulfill = false
            script.onReloadProcessed = { done.fulfill() }
            defer { script.onReloadProcessed = nil }
            try edit()
            await fulfillment(of: [done], timeout: failureBound)
        }
        XCTAssertNil(script.diagnostic)
        assertUpdates(explicitUpdates + 1)
        try await processed { try write("\n" + declaration("tile")) }
        XCTAssertNil(script.diagnostic)
        assertUpdates(explicitUpdates + 1)
        try await processed { try write(declaration("invalid")) }
        XCTAssertNotNil(script.diagnostic)
        XCTAssertEqual(settings.effectiveAppRules.first?.layout, .tile)
        assertUpdates(explicitUpdates + 1)
        try await processed { try write(declaration("float")) }
        XCTAssertNil(script.diagnostic)
        XCTAssertEqual(settings.effectiveAppRules.first?.layout, .float)
        assertUpdates(explicitUpdates + 2)
        try await processed { try FileManager.default.removeItem(at: file) }
        XCTAssertNil(script.diagnostic)
        XCTAssertEqual(settings.effectiveAppRules, [])
        assertUpdates(explicitUpdates + 3)
    }
}
