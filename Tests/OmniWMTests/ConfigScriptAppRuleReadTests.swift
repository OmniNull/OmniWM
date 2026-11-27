// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class ConfigScriptAppRuleReadTests: XCTestCase {
    private struct App {
        let bundleId: String
        let name: String
        var frame: CGRect?
    }

    private struct RuleCapture {
        let snapshot: ConfigScriptSnapshot
        let rows: [IPCRuleSnapshot]
    }

    private let workspaces = ["1", "2"]

    func testAppsShareCLIGroupingAndOrderWithCachedSizes() async throws {
        let fixture = try scene()
        let controller = fixture.controller
        let workspace = fixture.workspace(workspaces[0])
        let frame = try XCTUnwrap(fixture.manager.monitor(for: workspace)).visibleFrame
        let editor = App(bundleId: "fixture.editor", name: "A Editor", frame: frame)
        let terminal = App(bundleId: "fixture.terminal", name: "Z Terminal")
        let excluded = App(bundleId: "fixture.excluded", name: "Excluded")
        track(terminal, token: fixture.token(1), in: workspace, with: controller)
        track(editor, token: fixture.token(2), in: workspace, with: controller)
        track(editor, token: fixture.token(3), in: fixture.workspace(workspaces[1]), with: controller)
        track(excluded, token: fixture.token(4), in: workspace, with: controller)
        fixture.manager.setLayoutReason(.nativeFullscreen, for: fixture.token(4))

        let uncached = WindowToken(pid: pid_t.max, windowId: fixture.token(5).windowId)
        _ = WindowAdmissionTestSupport.track(uncached, in: workspace, controller: controller)
        let reads: ConfigScriptReads = [.apps, .workspaces]
        let snapshot = capture(reads, from: controller)
        let cli = IPCQueryRouter(controller: controller, sessionToken: "").appsResult().apps
        XCTAssertEqual(cli.map(\.bundleId), [editor.bundleId, "", terminal.bundleId])
        let rows = cli.map { app in
            let seeded = [editor, terminal].first { $0.bundleId == app.bundleId }
            if let seeded { XCTAssertEqual(app.appName, seeded.name) }
            return """
            { bundleId = \(lua(app.bundleId)), name = \(lua(seeded == nil ? nil : app.appName)),
              windowWidth = \(lua(seeded?.frame?.width)), windowHeight = \(lua(seeded?.frame?.height)) }
            """
        }.joined(separator: ",\n")
        try await invoke("""
        \(Self.compareRows)
        local expected = { \(rows) }
        omniwm.on('workspace.active', function(ctx)
            same(ctx.apps, expected, 'apps')
            assert(ctx.truncated.apps == false)
            assert(ctx.workspaces == nil and ctx.truncated.workspaces == nil)
        end, { reads = { 'apps' } })
        omniwm.on('workspace.active', function(ctx)
            assert(ctx.workspaces ~= nil and ctx.truncated.workspaces == false)
            assert(ctx.apps == nil and ctx.truncated.apps == nil)
        end, { reads = { 'workspaces' } })
        """, expecting: reads, snapshot: snapshot)
    }

    func testSavedRuleSnapshotsRefreshAfterLoadEditorAndCLIChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = SettingsFilePersistence(directory: root, startWatching: false, deferSaves: false)
        let settings = SettingsStore(
            persistence: persistence, runtimeState: RuntimeStateStore(directory: root), autosaveEnabled: false
        )
        let controller = WMController(settings: settings)
        controller.layoutRefreshController.suspendForLockScreen()
        defer { controller.layoutRefreshController.resetState() }
        let editor = AppRule(
            bundleId: "fixture.editor", appNameSubstring: "Editor", titleSubstring: "Project",
            axRole: kAXWindowRole as String, axSubrole: kAXStandardWindowSubrole as String,
            layout: .tile, assignToWorkspace: workspaces[0], assignToWorkspaceForAllWindows: true,
            initialContainerPrimarySpan: 0.5, minWidth: 720, minHeight: 540
        )
        let broken = AppRule(bundleId: "fixture.broken", titleRegex: "[", layout: .float)
        let scratchpad = AppRule(bundleId: "fixture.terminal", scratchpad: ScratchpadIndex.range.upperBound)
        let inserted = [editor, broken, scratchpad]
        var export = settings.toExport()
        export.appRules = inserted
        try SettingsLuauDocument.initialSource(export).write(to: persistence.fileURL, options: .atomic)
        persistence.handlePossibleSettingsFileChange()
        let loaded = ruleCapture(inserted, from: controller)
        let invalid = try XCTUnwrap(loaded.rows.first { $0.id == broken.id.uuidString })
        let regexDiagnostic = try XCTUnwrap(IPCRuleValidator.invalidRegexMessage(for: broken.titleRegex))
        XCTAssertFalse(invalid.isValid)
        XCTAssertEqual(invalid.invalidRegexMessage, regexDiagnostic)
        XCTAssertEqual(invalid.validationMessages, [regexDiagnostic])

        var draft = AppRuleDraft(rule: editor)
        draft.layoutAction = .float
        let edited = draft.makeRule(id: editor.id)
        let editorIndex = try XCTUnwrap(settings.appRules.firstIndex { $0.id == editor.id })
        settings.appRules[editorIndex] = edited
        controller.updateAppRules()
        let afterEdit = ruleCapture([edited, broken, scratchpad], from: controller)

        let cli = IPCRuleRouter(controller: controller, sessionToken: "")
        let moved = try await cli.handle(.move(id: scratchpad.id.uuidString, position: 1)).get()
        let wanted = [scratchpad, edited, broken]
        let afterMove = ruleCapture(wanted, from: controller)
        XCTAssertEqual(moved.rules, afterMove.rows)

        let scriptBundle = "fixture.script-only"
        let script = try await ConfigScriptLoader().evaluate(Data(
            "omniwm.rule { bundleId = '\(scriptBundle)', layout = 'float' }".utf8
        ), hyperMask: 0)
        let scriptRule = try XCTUnwrap(script.rules.first?.rule)
        XCTAssertTrue(settings.setScriptAppRules([scriptRule]))
        XCTAssertTrue(settings.effectiveAppRules.contains(scriptRule))
        let withScriptRule = ruleCapture(wanted, from: controller)
        XCTAssertEqual(withScriptRule.rows, afterMove.rows)

        for read in [loaded, afterEdit, afterMove, withScriptRule] {
            try await assertRuleRead(read)
        }
    }

    func testWholeReadLimitsDoNotSpillAcrossSectionsOrListeners() async throws {
        let fixture = try scene()
        let controller = fixture.controller
        controller.settings.appRules = []
        let reads: ConfigScriptReads = [.apps, .rules, .workspaces]
        let empty = capture(reads, from: controller)
        let workspace = fixture.workspace(workspaces[0])
        let apps = [
            App(bundleId: "fixture.kept", name: "A First"),
            App(bundleId: "fixture.oversized", name: String(repeating: "M", count: ConfigScriptSnapshot.byteLimit)),
            App(bundleId: "fixture.later", name: "Z Later")
        ]
        for (index, app) in apps.enumerated() {
            track(app, token: fixture.token(index + 1), in: workspace, with: controller)
        }
        let rowLimit = ConfigScriptSnapshot.rowLimit
        let rules = (0 ... rowLimit).map { AppRule(bundleId: "fixture.rule\($0)", layout: .tile) }
        controller.settings.appRules = rules
        let full = capture(reads, from: controller)
        let keptApp = try XCTUnwrap(apps.first)
        let keptRules = rules.prefix(rowLimit)
        for (snapshot, truncated) in [(empty, false), (full, true)] {
            let ruleIDs = (truncated ? keptRules.map { lua($0.id.uuidString) } : []).joined(separator: ",")
            try await invoke("""
            local expectedRules = { \(ruleIDs) }
            omniwm.on('workspace.active', function(ctx)
                assert(table.isfrozen(ctx.truncated) and table.isfrozen(ctx.apps) and table.isfrozen(ctx.rules))
                assert(ctx.truncated.apps == \(truncated) and ctx.truncated.rules == \(truncated))
                assert(ctx.truncated.workspaces == nil and ctx.workspaces == nil)
                if \(truncated) then
                    local app = assert(ctx.apps[1])
                    assert(#ctx.apps == 1 and app.bundleId == \(lua(keptApp.bundleId)))
                    assert(app.name == \(lua(keptApp.name)))
                else
                    assert(#ctx.apps == 0)
                end
                assert(#ctx.rules == #expectedRules)
                for index, rule in ctx.rules do
                    assert(rule.id == expectedRules[index] and rule.position == index)
                end
            end, { reads = { 'apps', 'rules' } })
            omniwm.on('workspace.active', function(ctx)
                assert(ctx.truncated.workspaces == false and #ctx.workspaces > 0)
                assert(ctx.truncated.apps == nil and ctx.apps == nil)
                assert(ctx.truncated.rules == nil and ctx.rules == nil)
            end, { reads = { 'workspaces' } })
            """, expecting: reads, snapshot: snapshot)
        }
    }

    private func ruleCapture(_ rules: [AppRule], from controller: WMController) -> RuleCapture {
        let snapshot = capture(.rules, from: controller)
        let rows = IPCQueryRouter(controller: controller, sessionToken: "").rulesResult().rules
        XCTAssertEqual(rows.map(\.id), rules.map { $0.id.uuidString })
        XCTAssertEqual(rows.map(\.position), rules.indices.map { $0 + 1 })
        XCTAssertEqual(rows.map(\.specificity), rules.map(\.specificity))
        XCTAssertEqual(rows.map(\.layout.rawValue), rules.map(\.effectiveLayoutAction.rawValue))
        return RuleCapture(snapshot: snapshot, rows: rows)
    }

    private func assertRuleRead(_ read: RuleCapture) async throws {
        let rows = read.rows.map { row in
            let diagnostics = row.validationMessages.map { lua($0) }.joined(separator: ", ")
            return """
            { id = \(lua(row.id)), position = \(row.position), specificity = \(row.specificity),
              bundleId = \(lua(row.bundleId)), appNameSubstring = \(lua(row.appNameSubstring)),
              titleSubstring = \(lua(row.titleSubstring)), titleRegex = \(lua(row.titleRegex)),
              axRole = \(lua(row.axRole)), axSubrole = \(lua(row.axSubrole)), layout = \(lua(row.layout.rawValue)),
              assignToWorkspace = \(lua(row.assignToWorkspace)),
              assignToWorkspaceForAllWindows = \(lua(row.assignToWorkspaceForAllWindows)),
              initialContainerPrimarySpan = \(lua(row.initialContainerPrimarySpan)),
              minWidth = \(lua(row.minWidth)), minHeight = \(lua(row.minHeight)), scratchpad = \(lua(row.scratchpad)),
              isValid = \(row.isValid), invalidRegexMessage = \(lua(row.invalidRegexMessage)),
              validationMessages = { \(diagnostics) } }
            """
        }.joined(separator: ",\n")
        try await invoke("""
        \(Self.compareRows)
        local expected = { \(rows) }
        omniwm.on('workspace.active', function(ctx)
            same(ctx.rules, expected, 'rules')
            assert(ctx.truncated.rules == false)
        end, { reads = { 'rules' } })
        """, expecting: .rules, snapshot: read.snapshot)
    }

    private static let compareRows = """
    local function same(row, expected, label)
        assert(type(row) == 'table' and table.isfrozen(row), label)
        for key, value in expected do
            local path = label .. '.' .. tostring(key)
            if type(value) == 'table' then
                same(row[key], value, path)
            else
                assert(row[key] == value, path)
            end
        end
        for key in row do assert(expected[key] ~= nil, label .. '.' .. tostring(key)) end
    end
    """

    private func scene() throws -> NiriGatherFixture {
        let display = NiriGatherFixture.monitor(displayId: UInt32(getpid()))
        return try NiriGatherFixture(
            prefix: "config-app-rule-reads", monitors: [display],
            workspaces: workspaces.map { .init(name: $0, monitor: display) }
        )
    }

    private func track(
        _ app: App, token: WindowToken, in workspace: WorkspaceDescriptor.ID, with controller: WMController
    ) {
        _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: controller)
        _ = controller.appInfoCache.info(for: token.pid) { _ in
            .init(name: app.name, bundleId: app.bundleId, icon: nil, activationPolicy: .regular)
        }
        if let frame = app.frame {
            controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame)
        }
    }

    private func capture(_ reads: ConfigScriptReads, from controller: WMController) -> ConfigScriptSnapshot {
        var pool = ConfigScriptSnapshotPool()
        return controller.configScriptSnapshot(reads: reads, target: controller.configScriptTarget(), pool: &pool)
    }

    private func lua(_ value: String?) -> String {
        value.map { String(reflecting: $0) } ?? "nil"
    }

    private func lua<T: CustomStringConvertible>(_ value: T?) -> String {
        value?.description ?? "nil"
    }

    private func invoke(
        _ source: String, expecting reads: ConfigScriptReads, snapshot: ConfigScriptSnapshot
    ) async throws {
        let result = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
        let generation = try XCTUnwrap(result.generation)
        XCTAssertEqual(result.events.reduce(into: ConfigScriptReads()) { $0.formUnion($1.reads) }, reads)
        for listener in result.events {
            _ = try await generation.invoke(
                function: listener.function, event: ConfigScriptEventPayload(name: "observed"), snapshot: snapshot
            )
        }
    }
}
