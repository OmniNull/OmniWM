// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
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
