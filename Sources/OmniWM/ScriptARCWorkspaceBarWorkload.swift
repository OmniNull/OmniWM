// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation

#if OMNIWM_SCRIPT_ARC_AUDIT
    import ScriptARCCounters

    @MainActor
    func measureWorkspaceBarReads(in directory: URL) async throws {
        let fixture = try ScriptARCFixture(
            directory: directory.appendingPathComponent("workspace-bar-reads"),
            snapshotRows: ScriptARCFixture.workspaceRows
        )
        defer { fixture.script.stop() }
        let controller = fixture.controller
        precondition(!controller.settings.workspaceBar.enabled)
        fixture.seedSnapshotFrames(ScriptARCFixture.workspaceRows)
        _ = try await fixture.acceptTitleScript("omniwm.command('Inspect', function() end)")
        fixture.snapshot([], route: "capture/workspace-bar-control", report: true)
        let apps = ScriptARCFixture.barReadApps
        fixture.populateBarReadApps(0 ..< apps / 4)
        fixture.populateSnapshotLayout(.niri)
        fixture.snapshot(.workspaceBar, route: "first/capture/workspace-bar", report: true)
        for report in [false, true] {
            fixture.snapshot(.workspaceBar, route: "capture/workspace-bar-64", report: report)
        }
        fixture.populateBarReadApps(apps / 4 ..< apps)
        fixture.populateSnapshotLayout(.niri)
        fixture.snapshot(.workspaceBar, route: "first/capture/workspace-bar-256", report: false)
        for report in [false, true] {
            fixture.snapshot(.workspaceBar, route: "capture/workspace-bar-256", report: report)
        }
        for report in [false, true] {
            fixture.snapshot([], route: "capture/no-workspace-bar", report: report)
        }
        try await measureGroupedWorkspaceBarReads(in: directory)
    }

    @MainActor
    private func measureGroupedWorkspaceBarReads(in directory: URL) async throws {
        let fixture = try ScriptARCFixture(
            directory: directory.appendingPathComponent("workspace-bar-grouped-reads"),
            snapshotRows: ScriptARCFixture.workspaceRows
        )
        defer { fixture.script.stop() }
        let controller = fixture.controller
        fixture.seedSnapshotFrames(ScriptARCFixture.workspaceRows)
        _ = try await fixture.acceptTitleScript("omniwm.command('Inspect', function() end)")
        controller.settings.workspaceBar.deduplicateAppIcons = true
        let apps = ScriptARCFixture.barReadApps
        for (range, route) in [
            (0 ..< apps / 4, "capture/workspace-bar-grouped-64"),
            (apps / 4 ..< apps, "capture/workspace-bar-grouped-256")
        ] {
            fixture.populateBarReadApps(range)
            fixture.warmBarReadCaches(range)
            fixture.populateSnapshotLayout(.niri)
            fixture.snapshot(.workspaceBar, route: "first/" + route, report: false)
            for report in [false, true] {
                fixture.snapshot(.workspaceBar, route: route, report: report)
            }
        }
        let monitor = controller.workspaceManager.monitors[0]
        let options = controller.settings.workspaceBar.resolved(for: monitor).projectionOptions
        for report in [false, true] {
            script_arc_begin()
            let projection = controller.workspaceBarProjection(for: monitor, projection: options)
            script_arc_end()
            if report { script_arc_report("projector/workspace-bar-grouped-256", "native/model", 0) }
            withExtendedLifetime(projection) {}
        }
    }

    @MainActor
    extension ScriptARCFixture {
        static let barReadApps = 64
        static let barReadWindowsPerApp = 4

        fileprivate func barReadWindow(app: Int, window: Int) -> Int {
            token.windowId + Self.workspaceRows + 1 + app * Self.barReadWindowsPerApp + window
        }

        fileprivate func populateBarReadApps(_ apps: Range<Int>) {
            let manager = controller.workspaceManager
            let workspace = manager.workspace(for: token)!
            for app in apps {
                let pid = token.pid + Int32(app + 1)
                let ax = AXUIElementCreateApplication(pid)
                for window in 0 ..< Self.barReadWindowsPerApp {
                    let windowNumber = barReadWindow(app: app, window: window)
                    let added = manager.addWindow(
                        AXWindowRef(element: ax, windowId: windowNumber), pid: pid, windowId: windowNumber,
                        to: workspace
                    )
                    precondition(added == WindowToken(pid: pid, windowId: windowNumber))
                }
            }
        }

        fileprivate func warmBarReadCaches(_ apps: Range<Int>) {
            for app in apps {
                let pid = token.pid + Int32(app + 1)
                _ = controller.appInfoCache.info(for: pid) { _ in
                    .init(
                        name: "Bar read application \(app)", bundleId: "test.omniwm.bar-read.\(app)",
                        icon: nil, activationPolicy: .regular
                    )
                }
                for window in 0 ..< Self.barReadWindowsPerApp {
                    AXWindowService.storeTitleCacheEntry(
                        windowId: UInt32(barReadWindow(app: app, window: window)),
                        title: "Bar read window \(app).\(window)"
                    )
                }
            }
        }
    }
#endif
