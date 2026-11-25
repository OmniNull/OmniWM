// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import ScriptARCCounters

@MainActor
func measureGather(in directory: URL) async throws {
    let fixture = try ScriptARCFixture(directory: directory.appendingPathComponent("gather"))
    fixture.populateSnapshotLayout(.niri)
    try await fixture.gatherRoutes()
}

@MainActor
extension ScriptARCFixture {
    fileprivate func gatherRoutes() async throws {
        let manager = controller.workspaceManager
        let workspace = manager.workspace(for: token)!
        let session = controller.scriptSession.identity
        let rows = (0 ..< Self.workspaceRows).map { WindowToken(pid: token.pid, windowId: token.windowId + $0) }
        let tiled = rows.filter { manager.windowMode(for: $0) == .tiling }
        let floating = rows.first { manager.windowMode(for: $0) == .floating }!
        precondition(tiled.count >= 4)
        func list(_ windows: [WindowToken]) -> String {
            windows.map { "\"" + ConfigScriptWindowID.string($0, session: session) + "\"" }.joined(separator: ", ")
        }
        _ = try await acceptTitleScript("""
        local wm = omniwm
        wm.keymap.set("Control+Option+1", function() wm.dispatch("window", "gather", { \(list([tiled[0], tiled[1]])) }) end)
        wm.keymap.set("Control+Option+2", function() wm.dispatch("window", "gather", { \(list([tiled[2], tiled[3]])) }) end)
        wm.keymap.set("Control+Option+3", function() wm.dispatch("window", "gather", { \(list([tiled[0], floating])) }) end)
        """)
        await script.callbackQueue!.waitForAuditPark()
        let engine = controller.niriEngine!
        func columns() -> [[WindowToken]] {
            engine.columns(in: workspace).map { $0.windowNodes.map(\.token) }
        }
        precondition(tiled.allSatisfy { window in columns().contains([window]) })
        for (chord, report) in [("Control+Option+1", false), ("Control+Option+2", true)] {
            try await function(binding(chord), route: "gather/join", busy: false, report: report)
        }
        precondition(columns().contains([tiled[0], tiled[1]]) && columns().contains([tiled[2], tiled[3]]))
        let joined = columns()
        for (chord, report) in [("Control+Option+1", false), ("Control+Option+2", true)] {
            try await function(binding(chord), route: "gather/unchanged", busy: false, report: report)
        }
        precondition(columns() == joined && script.diagnostic == nil)
        let refused = try binding("Control+Option+3")
        for report in [false, true] {
            precondition(key(refused, measured: true) == .executed)
            guard let queue = script.callbackQueue, let worker = queue.worker else {
                throw ScriptARCError("A refused gather needs a worker")
            }
            script_arc_follow(unsafeBitCast(worker, to: UnsafeRawPointer.self), false)
            await queue.waitForAuditPark()
            script_arc_finish()
            precondition(script.diagnostic?.hasSuffix("window gather: windowActionFailed.") == true)
            if report { script_arc_report("gather/refused", "settings/key", 1) }
        }
        precondition(columns() == joined)
    }
}
