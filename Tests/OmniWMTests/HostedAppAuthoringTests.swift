// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

@MainActor
final class HostedAppAuthoringTests: XCTestCase {
    func testDiscoveredAppsHaveExactUnboundPaletteActionsAndExistingCLIIPCCommands() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let app = authoring(in: fixture)
        defer { try? FileManager.default.removeItem(at: app.directory) }
        try app.write()
        await fixture.controller.shellAppCatalog.refresh()
        let items = CommandPaletteSearch.buildCommandItems(from: fixture.controller)
        let actions = [
            (false, "app-open", "Open \(app.title)"),
            (true, "app-new-window", "New \(app.title) Window")
        ]
        for (newWindow, word, title) in actions {
            let expected = newWindow ? HotkeyCommand.shellAppNewWindow(app.id) : .shellAppOpen(app.id)
            let item = try XCTUnwrap(items.first { $0.spec.command == expected })
            XCTAssertEqual(item.spec.title, title)
            XCTAssertEqual(item.spec.defaultBinding, .unassigned)
            XCTAssertFalse(item.hasShortcut)
            XCTAssertEqual(ActionCatalog.spec(for: item.spec.id)?.command, expected)
            XCTAssertEqual(HotkeyBindingRegistry.command(for: item.spec.id), expected)
            let reconciled = HotkeyBindingRegistry.reconcilingWorkspaceNumberBindings(
                [try XCTUnwrap(HotkeyBindingRegistry.makeBinding(id: item.spec.id, binding: .unassigned))],
                workspaceNames: []
            )
            XCTAssertEqual(reconciled.map(\.command), [expected])
            let request = try XCTUnwrap(IPCCommandRequest(commandWords: [word, app.id]))
            let cli = try CLIParser.parse(arguments: ["omniwmctl", "command", word, app.id])
            XCTAssertEqual(cli.request.payload, .command(request))
            XCTAssertEqual(
                IPCCommandRouter(controller: fixture.controller, sessionToken: app.id).handle(request),
                .executed
            )
        }
        XCTAssertEqual(fixture.manager.runtimes.count, actions.count)
        for runtime in fixture.manager.runtimes.values {
            await readyHosted(runtime)
            XCTAssertNil(runtime.failure)
            XCTAssertEqual(runtime.context.viewName, app.view)
            XCTAssertTrue(hostedSheetLabels(runtime.surface).contains("Local module fixture"))
        }
        let windows = fixture.manager.windows
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.shellAppOpen(app.id)), .executed)
        XCTAssertEqual(fixture.manager.windows, windows)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    func testCatalogReloadAndSourceRemovalPreserveOpenOwnersAndInput() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let app = authoring(in: fixture, view: "window")
        defer { try? FileManager.default.removeItem(at: app.directory) }
        let source = try String(
            contentsOf: fixture.definition.folder.appendingPathComponent("init.luau"),
            encoding: .utf8
        )
        try app.write(source: source)
        await fixture.controller.shellAppCatalog.refresh()
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.shellAppOpen(app.id)), .executed)
        let runtime = try XCTUnwrap(fixture.manager.runtimes.values.first)
        await readyHosted(runtime)
        let package = runtime.package
        let input = try XCTUnwrap(runtime.surface.textInputs.values.first)
        let message = "State survives app discovery"
        try await applyHosted(message, to: runtime)
        let sourceView = runtime.surface.view
        let tokens = Set(fixture.manager.windows.keys)

        try app.write(
            manifest: app.manifest.replacingOccurrences(of: app.title, with: "New declaration"),
            source: source
        )
        await fixture.controller.shellAppCatalog.refresh()
        XCTAssertEqual(fixture.controller.shellAppCatalog.definitions[app.id]?.title, "New declaration")
        XCTAssertEqual(runtime.definition.title, app.title)
        XCTAssertTrue(runtime.package === package)
        XCTAssertTrue(runtime.surface.view === sourceView)
        XCTAssertTrue(runtime.surface.textInputs.values.contains { $0 === input })
        XCTAssertTrue(hostedSheetLabels(runtime.surface).contains(message))
        XCTAssertEqual(Set(fixture.manager.windows.keys), tokens)

        try FileManager.default.removeItem(at: app.folder)
        await fixture.controller.shellAppCatalog.refresh()
        XCTAssertNil(fixture.controller.shellAppCatalog.definitions[app.id])
        XCTAssertFalse(runtime.closed)
        XCTAssertEqual(Set(fixture.manager.windows.keys), tokens)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.shellAppNewWindow(app.id)), .notFound)
        XCTAssertTrue(hostedSheetLabels(runtime.surface).contains(message))
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    private func authoring(in fixture: HostedManagementFixture, view: String = "main") -> ShellAppAuthoringFixture {
        ShellAppAuthoringFixture(
            config: fixture.controller.settings.settingsFileURL.deletingLastPathComponent(), view: view
        )
    }
}
