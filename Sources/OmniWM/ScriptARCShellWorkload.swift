// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

#if OMNIWM_SCRIPT_ARC_AUDIT
    @MainActor
    func measureShellReads(in directory: URL) async throws {
        let root = directory.appendingPathComponent("shell-read")
        let fixture = try ScriptARCFixture(directory: root)
        defer { fixture.script.stop() }
        _ = try await fixture.acceptTitleScript("omniwm.command('Inspect', function() end)")
        fixture.snapshot([], route: "capture/shell-control", report: true)
        let rowLimit = ConfigScriptSnapshot.rowLimit
        for (label, widgetCount) in [("under-cap", 1), ("over-cap", rowLimit)] {
            let rows = min(rowLimit, fixture.populateShellReport(in: root, widgetCount: widgetCount))
            for report in [false, true] {
                fixture.snapshot(.shell, route: "capture/shell-\(label)", report: report, expectedRows: rows)
            }
        }
        fixture.snapshot([], route: "capture/no-shell", report: true)
    }

    extension ScriptARCFixture {
        func populateShellReport(in directory: URL, widgetCount: Int) -> Int {
            let host = ShellWidgetHost(
                configDirectory: directory, resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
                resourceStore: ShellResourceStore(directory: directory.appendingPathComponent("shell-resources")),
                world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {}, onCommand: { _, _ in },
                onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in }, onPopoutChange: {},
                onTitleDemandChange: { _ in }
            )
            let names = (0 ..< widgetCount).map { "script-arc-shell-widget-\($0)" }
            host.config.leading = names
            for name in names {
                let url = directory.appendingPathComponent("widgets/\(name)/init.luau")
                let widget = ShellWidgetHost.WidgetState(name: name, sourceURL: url)
                widget.lastFailure = ShellScriptFailure(kind: .compile, message: "Fixture widget failed to compile")
                host.widgets[name] = widget
            }
            let problems = ["Fixture shell has a configuration problem"]
            host.applyConfig(host.config, problems: problems)
            controller.workspaceBarManager.shellHost = host
            return 1 + names.count + problems.count
        }
    }
#endif
