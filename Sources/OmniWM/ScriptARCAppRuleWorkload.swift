// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation

#if OMNIWM_SCRIPT_ARC_AUDIT
    @MainActor
    func measureAppAndRuleReads(in directory: URL) async throws {
        let fixture = try ScriptARCFixture(
            directory: directory.appendingPathComponent("app-rule-reads"), snapshotRows: ScriptARCFixture.workspaceRows
        )
        defer { fixture.script.stop() }
        fixture.seedSnapshotFrames(ScriptARCFixture.workspaceRows)
        _ = try await fixture.acceptTitleScript("omniwm.command('Inspect', function() end)")
        fixture.snapshot([], route: "capture/app-rule-control", report: true)
        let rowLimit = ConfigScriptSnapshot.rowLimit
        fixture.snapshot(.apps, route: "first/capture/apps-grouped", report: true, expectedRows: 1)
        for report in [false, true] {
            fixture.snapshot(.apps, route: "capture/apps-grouped", report: report, expectedRows: 1)
        }
        fixture.populateAppRuleReadLists(rowLimit: rowLimit)
        for report in [false, true] {
            fixture.snapshot(.apps, route: "capture/apps-over-cap", report: report, expectedRows: rowLimit)
            fixture.snapshot(.rules, route: "capture/rules-over-cap", report: report, expectedRows: rowLimit)
            fixture.snapshot([], route: "capture/no-apps-or-rules", report: report)
        }
    }

    @MainActor
    extension ScriptARCFixture {
        fileprivate func populateAppRuleReadLists(rowLimit: Int) {
            let manager = controller.workspaceManager
            let workspace = manager.workspace(for: token)!
            let firstWindowNumber = token.windowId + Self.workspaceRows
            let ax = AXUIElementCreateApplication(token.pid)
            for index in 0 ..< rowLimit {
                let pid = token.pid + Int32(index + 1)
                let windowNumber = firstWindowNumber + index
                let bundleId = "test.omniwm.app-read.\(index)"
                _ = controller.appInfoCache.info(for: pid) { _ in
                    .init(
                        name: "Snapshot fixture application \(index)",
                        bundleId: bundleId,
                        icon: nil,
                        activationPolicy: .regular
                    )
                }
                let window = manager.addWindow(
                    AXWindowRef(element: ax, windowId: windowNumber), pid: pid, windowId: windowNumber, to: workspace
                )
                precondition(window == WindowToken(pid: pid, windowId: windowNumber))
            }
            controller.settings.appRules = (0 ... rowLimit).map {
                AppRule(bundleId: "test.omniwm.rule-read.\($0)", titleRegex: "[", layout: .float)
            }
        }
    }
#endif
