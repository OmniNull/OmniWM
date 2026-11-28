// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
func measureWindowMarks(in directory: URL) async throws {
    for (route, insertsMark) in [("mark/set-changed", true), ("mark/set-unchanged", false)] {
        let fixture = try ScriptARCFixture(directory: directory.appendingPathComponent(route))
        defer { fixture.script.stop() }
        try await fixture.markSet(route: route, insertsMark: insertsMark)
    }

    let route = "mark/summon-refused"
    let fixture = try ScriptARCFixture(directory: directory.appendingPathComponent(route))
    defer { fixture.script.stop() }
    try await fixture.refusedMarkSummon(route: route)
}

@MainActor
func measureMarkReads(in directory: URL) async throws {
    let fixture = try ScriptARCFixture(directory: directory.appendingPathComponent("mark-reads"))
    defer { fixture.script.stop() }
    _ = try await fixture.acceptTitleScript("omniwm.command('Inspect', function() end)")
    let registry = fixture.controller.windowMarkRegistry
    let rowLimit = ConfigScriptSnapshot.rowLimit
    var populated = 0
    for (count, route) in [
        (ScriptARCFixture.workspaceRows, "capture/marks-under-cap"),
        (rowLimit, "capture/marks-at-cap"),
        (rowLimit + 1, "capture/marks-over-cap")
    ] {
        for index in populated ..< count {
            let window = WindowToken(
                pid: fixture.token.pid, windowId: fixture.token.windowId + index % ScriptARCFixture.totalRows
            )
            precondition(registry.set("snapshot-audit-mark-\(index)", for: window) == .inserted)
        }
        populated = count
        if count == rowLimit {
            fixture.snapshot(.marks, route: "capture/marks-ordering", report: true, expectedRows: rowLimit)
        }
        for report in [false, true] {
            fixture.snapshot(.marks, route: route, report: report, expectedRows: min(count, rowLimit))
        }
    }
    for report in [false, true] {
        fixture.snapshot([], route: "capture/no-marks", report: report)
    }
}

@MainActor
extension ScriptARCFixture {
    private static let markName = "workspace-editor"
    private static let markChord = "Control+Option+M"

    private func markBinding(_ action: String) async throws -> HotkeyCommand {
        let queue = try await acceptTitleScript("""
        omniwm.keymap.set("\(Self.markChord)", function()
            omniwm.dispatch("mark", "\(action)", "\(Self.markName)")
        end)
        """)
        await queue.waitForAuditPark()
        return try binding(Self.markChord)
    }

    fileprivate func markSet(route: String, insertsMark: Bool) async throws {
        let registry = controller.windowMarkRegistry
        let name = Self.markName
        precondition(controller.workspaceManager.nativeManagedFocusToken == token)
        if !insertsMark {
            precondition(registry.set(name, for: token) == .inserted)
        }
        let command = try await markBinding("set")
        let expectedBefore: WindowMarkRegistry.LookupResult = insertsMark ? .unknown : .found(token)
        for report in [false, true] {
            precondition(registry.lookup(name) == expectedBefore)
            try await function(command, route: route, busy: false, report: report)
            precondition(registry.lookup(name) == .found(token))
            if insertsMark && !report {
                precondition(registry.remove(name) == .removed)
            }
        }
    }

    fileprivate func refusedMarkSummon(route: String) async throws {
        let manager = controller.workspaceManager
        let workspace = manager.workspace(for: otherWindow)!
        populateSnapshotLayout(.niri)
        precondition(manager.confirmManagedFocus(
            otherWindow, in: workspace, onMonitor: manager.monitorId(for: workspace), activateWorkspaceOnMonitor: false
        ))
        precondition(manager.nativeManagedFocusToken == otherWindow && manager.selectedManagedToken == otherWindow)
        let registry = controller.windowMarkRegistry
        let name = Self.markName
        precondition(registry.set(name, for: otherWindow) == .inserted)

        let command = try await markBinding("summon")
        precondition(script.diagnostic == nil)
        try await refusedFunction(
            command, route: route, diagnostic: "mark summon: cannot summon the anchor window.", report: true
        )
        precondition(registry.lookup(name) == .found(otherWindow))
        precondition(manager.workspace(for: otherWindow) == workspace)
    }
}
