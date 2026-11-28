// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class ConfigScriptWorkspaceBarReadTests: XCTestCase {
    private struct App {
        let bundleId: String
        let name: String
    }

    private let workspaces = ["1", "2"]

    func testWorkspaceBarSharesTheCLIsPillsFromWarmCaches() async throws {
        let fixture = try scene()
        let controller = fixture.controller
        controller.settings.workspaceBar.enabled = false
        controller.settings.workspaceBar.deduplicateAppIcons = true
        let first = fixture.workspace(workspaces[0])
        let editor = App(bundleId: "fixture.editor", name: "Editor")
        let terminal = App(bundleId: "fixture.terminal", name: "Terminal")
        let editorWindows = [fixture.token(1), fixture.token(3)]
        let terminalWindows = [fixture.token(2)]
        let otherEditorWindow = fixture.token(4)
        defer {
            for token in editorWindows + terminalWindows + [otherEditorWindow] {
                AXWindowService.invalidateCachedTitle(windowId: UInt32(token.windowId))
            }
        }
        track(editor, token: editorWindows[0], title: "Notes", in: first, with: controller)
        track(terminal, token: terminalWindows[0], title: nil, in: first, with: controller)
        track(editor, token: editorWindows[1], title: "Plan", in: first, with: controller)
        track(editor, token: otherEditorWindow, title: "Todo", in: fixture.workspace(workspaces[1]), with: controller)

        let reads: ConfigScriptReads = [.workspaceBar]
        let snapshot = capture(reads, from: controller)
        let cli = IPCQueryRouter(controller: controller, sessionToken: "").workspaceBarResult()
        let firstWorkspace = try XCTUnwrap(cli.monitors.first?.workspaces.first)
        XCTAssertEqual(firstWorkspace.windows.map(\.windowCount), [editorWindows.count, terminalWindows.count])
        try await invoke("""
        \(Self.compareRows)
        local expected = \(expectedBar(cli, controller: controller))
        omniwm.on('workspace.active', function(ctx)
            same(ctx.workspaceBar, expected, 'workspaceBar')
            assert(ctx.truncated.workspaceBar == false)
        end, { reads = { 'workspaceBar' } })
        omniwm.on('workspace.active', function(ctx)
            assert(ctx.workspaceBar == nil)
        end)
        """, expecting: reads, snapshot: snapshot)
    }

    func testTogglingWindowModeKeepsWorkspaceBarPillOrderInSyncWithCLI() async throws {
        let fixture = try scene()
        let controller = fixture.controller
        let manager = controller.workspaceManager
        controller.settings.workspaceBar.enabled = false
        controller.settings.workspaceBar.deduplicateAppIcons = true
        controller.settings.workspaceBar.showFloatingWindows = true
        let workspace = fixture.workspace(workspaces[0])
        let app = App(bundleId: "fixture.editor", name: "Editor")
        let first = fixture.token(7)
        let second = fixture.token(8)
        defer {
            for token in [first, second] {
                AXWindowService.invalidateCachedTitle(windowId: UInt32(token.windowId))
            }
        }
        track(app, token: first, title: "Notes", in: workspace, with: controller)
        track(app, token: second, title: "Plan", in: workspace, with: controller)
        XCTAssertTrue(manager.setWindowMode(.floating, for: first))
        XCTAssertTrue(manager.setWindowMode(.floating, for: second))
        XCTAssertTrue(manager.setWindowMode(.tiling, for: first))
        XCTAssertTrue(manager.setWindowMode(.floating, for: first))

        let snapshot = capture(.workspaceBar, from: controller)
        let cli = IPCQueryRouter(controller: controller, sessionToken: "").workspaceBarResult()
        let item = try XCTUnwrap(cli.monitors.first?.workspaces.first { $0.id == workspace.uuidString })
        let pill = try XCTUnwrap(item.windows.first)
        let expectedIDs = [second, first].map { IPCWindowOpaqueID.encode(token: $0, sessionToken: "") }
        XCTAssertEqual(item.windows.count, 1)
        XCTAssertEqual(pill.id, expectedIDs[0])
        XCTAssertEqual(pill.allWindows.map(\.id), expectedIDs)
        try await invoke("""
        \(Self.compareRows)
        local expected = \(expectedBar(cli, controller: controller))
        omniwm.on('workspace.active', function(ctx)
            same(ctx.workspaceBar, expected, 'workspaceBar after mode change')
        end, { reads = { 'workspaceBar' } })
        """, expecting: .workspaceBar, snapshot: snapshot)
    }

    func testColdCachesLeaveNamesAndTitlesOutAndGroupByProcess() async throws {
        let fixture = try scene()
        let controller = fixture.controller
        controller.settings.workspaceBar.enabled = false
        controller.settings.workspaceBar.deduplicateAppIcons = true
        let first = fixture.workspace(workspaces[0])
        let tokens = [fixture.token(5), fixture.token(6)]
        for token in tokens {
            AXWindowService.invalidateCachedTitle(windowId: UInt32(token.windowId))
            _ = WindowAdmissionTestSupport.track(token, in: first, controller: controller)
        }
        let session = controller.scriptSession.identity
        let pills = tokens.map { token in
            let id = lua(ConfigScriptWindowID.string(token, session: session))
            return "{ id = \(id), focused = false, windowCount = 1, windows = { { id = \(id), focused = false } } }"
        }.joined(separator: ", ")

        let snapshot = capture(.workspaceBar, from: controller)
        try await invoke("""
        \(Self.compareRows)
        omniwm.on('workspace.active', function(ctx)
            local display = ctx.workspaceBar.displays[1]
            assert(display.visible == false and display.enabled == false)
            same(display.workspaces[1].windows, { \(pills) }, 'pills')
        end, { reads = { 'workspaceBar' } })
        """, expecting: .workspaceBar, snapshot: snapshot)
    }

    private func expectedBar(_ result: IPCWorkspaceBarQueryResult, controller: WMController) throws -> String {
        let session = controller.scriptSession.identity
        func id(_ opaque: String) throws -> String {
            let address = try XCTUnwrap(IPCWindowOpaqueID.decode(opaque))
            return lua(ConfigScriptWindowID.string(
                WindowToken(pid: address.pid, windowId: address.windowId), session: session
            ))
        }
        func pills(_ apps: [IPCWorkspaceBarApp]) throws -> String {
            try apps.map { app in
                let windows = try app.allWindows.map { window in
                    "{ id = \(try id(window.id)), title = \(lua(window.title)), focused = \(window.isFocused) }"
                }.joined(separator: ", ")
                return """
                { id = \(try id(app.id)), bundleId = \(lua(app.bundleId)), name = \(lua(app.appName)),
                  focused = \(app.isFocused), windowCount = \(app.windowCount), windows = { \(windows) } }
                """
            }.joined(separator: ",\n")
        }
        let displays = try zip(result.monitors, controller.workspaceManager.monitors).map { cli, monitor in
            let scratchpads = try cli.scratchpads.map { scratchpad in
                """
                { index = \(scratchpad.index), label = \(lua(scratchpad.label)), visible = \(scratchpad.isVisible),
                  windows = { \(try pills(scratchpad.windows)) } }
                """
            }.joined(separator: ",\n")
            let workspaces = try cli.workspaces.map { workspace in
                """
                { id = \(lua(workspace.id)), rawName = \(lua(workspace.rawName)),
                  displayName = \(lua(workspace.displayName)), number = \(lua(workspace.number)),
                  focused = \(workspace.isFocused), windows = { \(try pills(workspace.windows)) } }
                """
            }.joined(separator: ",\n")
            return """
            { id = \(lua(monitor.id.scriptIdentifier)), name = \(lua(cli.name)), enabled = \(cli.enabled),
              visible = \(cli.isVisible), showLabels = \(cli.showLabels),
              backgroundOpacity = \(cli.backgroundOpacity), barHeight = \(cli.barHeight),
              scratchpads = { \(scratchpads) }, workspaces = { \(workspaces) } }
            """
        }.joined(separator: ",\n")
        let interaction = lua(controller.workspaceManager.interactionMonitorId?.scriptIdentifier)
        return "{ interactionDisplay = \(interaction), displays = { \(displays) } }"
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
            prefix: "config-workspace-bar-reads", monitors: [display],
            workspaces: workspaces.map { .init(name: $0, monitor: display) }
        )
    }

    private func track(
        _ app: App, token: WindowToken, title: String?, in workspace: WorkspaceDescriptor.ID,
        with controller: WMController
    ) {
        _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: controller)
        _ = controller.appInfoCache.info(for: token.pid) { _ in
            .init(name: app.name, bundleId: app.bundleId, icon: nil, activationPolicy: .regular)
        }
        if let title {
            AXWindowService.storeTitleCacheEntry(windowId: UInt32(token.windowId), title: title)
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
