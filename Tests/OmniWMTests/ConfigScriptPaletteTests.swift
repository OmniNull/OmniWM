// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptPaletteTests: XCTestCase {
    private func install(in fixture: CommandPaletteFocusFixture) -> ConfigScriptController {
        let script = ConfigScriptController(
            fileURL: fixture.root.appendingPathComponent("init.luau"),
            settings: fixture.controller.settings
        ) { _ in }
        fixture.controller.configScript = script
        return script
    }

    private func publish(_ lines: [String], into script: ConfigScriptController) async throws {
        let mask = HyperKeyModifiers.default.carbonMask
        let evaluation = try await ConfigScriptLoader().evaluate(
            Data(lines.joined(separator: "\n").utf8), hyperMask: mask
        )
        XCTAssertTrue(script.apply(ConfigScriptLoad(versions: [:], result: .success(evaluation)), hyperMask: mask))
        XCTAssertNil(script.diagnostic)
    }

    func testReloadReplacesOpenPaletteEntriesAndSettingsSearchFindsTheirSources() async throws {
        var failures: [String] = []
        let fixture = CommandPaletteFocusFixture { environment in
            environment.presentCommandFailure = { failures.append($0) }
        }
        defer { fixture.cleanup() }
        let script = install(in: fixture)
        let first = "Resize TextEdit"
        let replacement = "Resize Browser"
        let binding = "local wm = omniwm"
        try await publish([binding, "wm.command('\(first)', function() end)"], into: script)
        _ = try fixture.show(mode: .commands)
        fixture.palette.selectMode(.commands)
        fixture.palette.searchText = first
        let initial = try XCTUnwrap(fixture.palette.filteredCommandItems.first)
        XCTAssertEqual(initial.spec.localizedTitle, first)
        XCTAssertEqual(initial.spec.category, .script)
        let source = try XCTUnwrap(script.acceptedCommands.first)
        XCTAssertEqual(source.sourceLocation, "init.luau:\([binding].count + 1)")
        for text in [first.uppercased(), source.sourceLocation] {
            XCTAssertEqual(
                HotkeySettingsDisplayModel.search(text, scriptCommands: script.acceptedCommands).map(\.name),
                [first]
            )
        }
        try await publish(["omniwm.command('\(replacement)', function() end)"], into: script)
        XCTAssertTrue(fixture.palette.filteredCommandItems.isEmpty)
        XCTAssertFalse(fixture.palette.commandItems.contains { $0.id == initial.id })
        fixture.palette.searchText = replacement
        XCTAssertEqual(fixture.palette.filteredCommandItems.map(\.spec.localizedTitle), [replacement])
        fixture.palette.actionExecutor.perform(.command(fixture.controller, initial.spec.command, nil))
        XCTAssertEqual(failures, ["This script command is no longer available."])
        try await publish([], into: script)
        XCTAssertTrue(fixture.palette.filteredCommandItems.isEmpty)
        XCTAssertTrue(script.acceptedCommands.isEmpty)
    }

    func testSelectedFunctionCapturesTheWindowAfterTheOriginalAppRegainsFocus() async throws {
        let app = NSRunningApplication.current
        var frontmost: NSRunningApplication? = app
        var restoredID: CGWindowID?
        var restoring = false
        let fixture = CommandPaletteFocusFixture { environment in
            environment.ownProcessIdentifier = { app.processIdentifier + 1 }
            environment.runningApplication = { $0 == app.processIdentifier ? app : nil }
            environment.frontmostApplication = { frontmost }
            environment.restoreCommandFocus = { target in
                restoring = true
                restoredID = target.focusedWindowID
                return true
            }
            environment.focusedWindowID = { _ in restoredID }
        }
        defer { fixture.cleanup() }
        let controller = fixture.controller
        let script = install(in: fixture)
        let name = "Inspect restored window"
        let bundleId = "test.restored"
        try await publish([
            "omniwm.command('\(name)', function(ctx)",
            "    assert(ctx.windowId and ctx.bundleId == '\(bundleId)', 'wrong window')",
            "end)"
        ], into: script)
        let queue = try XCTUnwrap(script.callbackQueue)
        _ = try fixture.show(mode: .commands)
        fixture.palette.selectMode(.commands)
        fixture.palette.searchText = name
        let item = try XCTUnwrap(fixture.palette.filteredCommandItems.first)
        fixture.palette.selectedItemID = .command(item.id)
        frontmost = nil
        let entries = omni_config_vm_entry_count()
        fixture.palette.selectCurrent()
        XCTAssertTrue(restoring)
        XCTAssertFalse(fixture.palette.isVisible)
        XCTAssertFalse(queue.hasPendingWork)
        XCTAssertEqual(omni_config_vm_entry_count(), entries)

        let manager = controller.workspaceManager
        let workspace = try XCTUnwrap(controller.activeWorkspace())
        let token = WindowToken(
            pid: app.processIdentifier,
            windowId: Int(restoredID ?? CGWindowID(app.processIdentifier))
        )
        let metadata = HostedWindowMetadata(appId: bundleId, title: name, minimumSize: CGSize(width: 160, height: 100))
        XCTAssertEqual(manager.addHostedWindow(
            token: token, metadata: metadata, to: workspace.id, initialFrame: CGRect(
                origin: .zero,
                size: metadata.minimumSize
            )
        ), token)
        _ = manager.setManagedFocus(token, in: workspace.id)
        frontmost = app
        fixture.palette.actionExecutor.applicationActivated(pid: app.processIdentifier)
        XCTAssertTrue(queue.hasPendingWork)
        await queue.waitUntilParked()
        XCTAssertNil(script.diagnostic)
        assertConfigVMEntries(1, since: entries)
        XCTAssertNil(script.onCommandsChanged)
    }
}
