// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMIPC
import ScriptARCCounters

@MainActor
package func runScriptARCWorkspaceKeys(directory: URL, measured: Bool = true, calibratePlatform: Bool = false) throws {
    if calibratePlatform {
        _ = NSApplication.shared
        script_arc_install()
        script_arc_begin()
        let application = AXUIElementCreateApplication(getpid())
        var displays: UInt32 = 0
        let status = CGGetOnlineDisplayList(0, nil, &displays)
        script_arc_end()
        withExtendedLifetime(application) { precondition(status == .success) }
    }
    for prime in [false, true] {
        let fixture = try ScriptARCFixture(
            directory: directory.appendingPathComponent(prime ? "warm-navigation" : "navigation"),
            snapshotRows: 1
        )
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let monitor = manager.monitors.first!.id
        let first = manager.workspace(for: fixture.token)!
        let second = manager.workspaceId(named: "2")!
        _ = manager.removeWindow(pid: fixture.token.pid, windowId: fixture.token.windowId)
        defer { controller.layoutRefreshController.resetState() }
        for switches in [false, true] {
            controller.settings.workspaceBar.hideEmptyWorkspaces = !switches
            for (action, name) in [(WorkspaceAction.next, "next"), (.previous, "previous"), (.backAndForth, "back")] {
                for report in [false, true] {
                    controller.layoutRefreshController.resetState()
                    _ = manager.setActiveWorkspace(first, on: monitor)
                    manager.updateMonitorSession(monitor) { $0.previousVisibleWorkspaceId = switches ? second : nil }
                    if prime { precondition(controller.activeWorkspace()?.id == first) }
                    let route = (prime ? "warm/workspace-key/" : "workspace-key/") + name +
                        (switches ? "-switch" : "-noop")
                    let result = fixture.key(.workspace(action), measured: measured)
                    if measured, report { script_arc_report(route, "native", 0) }
                    precondition(result == (switches ? .executed : .noChange))
                    precondition(controller.activeWorkspace()?.id == (switches ? second : first))
                }
            }
        }
    }
}

@MainActor
extension ScriptARCFixture {
    func commandSelectorKeys() async throws {
        let workspace = controller.activeWorkspace()!.name
        let index = WorkspaceIDPolicy.workspaceNumber(from: workspace)!
        let queue = try await acceptTitleScript("""
        local wm = omniwm
        wm.keymap.set("Control+Option+N", function() local action = wm.cmd.switchWorkspace(\(index)) end)
        wm.keymap.set("Control+Option+S", function() local action = wm.cmd.switchWorkspace("\(index)") end)
        wm.keymap.set("Control+Option+I", function() wm.cmd.switchWorkspace(0) end)
        wm.keymap.set("Control+Option+W", function(c) wm.dispatch("window", "move-to-workspace", c.windowId, \(index)) end)
        wm.keymap.set("Control+Option+T", function(c) wm.dispatch("window", "move-to-workspace", c.windowId, "\(index)") end)
        """)
        await queue.waitForAuditPark()
        for report in [false, true] {
            try await function(binding("Control+Option+N"), route: "cmd/integer", busy: false, report: report)
            try await function(binding("Control+Option+S"), route: "cmd/string-index", busy: false, report: report)
            try await function(binding("Control+Option+W"), route: "window/integer", busy: false, report: report)
            try await function(binding("Control+Option+T"), route: "window/string-index", busy: false, report: report)
        }
        let invalid = try binding("Control+Option+I")
        precondition(key(invalid, measured: true) == .executed)
        try await measureWorker(seed: false)
        guard script.diagnostic?.contains("positive safe integer selector") == true else {
            throw ScriptARCError(script.diagnostic ?? "Missing selector refusal")
        }
        script_arc_report("cmd/invalid-selector", "settings/key", 1)
    }
}
