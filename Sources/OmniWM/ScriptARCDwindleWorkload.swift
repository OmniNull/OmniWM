// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

@MainActor
func measureDwindleReads(in directory: URL) async throws {
    let mixed = try ScriptARCFixture(directory: directory.appendingPathComponent("mixed-dwindle"))
    mixed.populateSnapshotLayout(.dwindle)
    try await mixed.mixedReads(
        "dwindle", probe: "e.dwindle", rows: "#e.windows == \(ScriptARCFixture.totalRows)",
        routes: ["shared-dwindle", "shared-plain-dwindle", "solo-dwindle", "solo-plain-dwindle"]
    )
    let limit = ConfigScriptSnapshot.rowLimit
    try await measureSnapshotRows(
        in: directory.appendingPathComponent("dwindle-rows"),
        counts: [ScriptARCFixture.workspaceRows, ScriptARCFixture.totalRows, limit], routes: []
    ) { fixture, count in
        fixture.populateSnapshotLayout(.dwindle)
        fixture.treeCaptures("tree", count: count, cold: true)
        fixture.groupDwindleTiles()
        fixture.treeCaptures("group", count: count, cold: false)
        fixture.populateSnapshotLayout(.niri)
        fixture.snapshot(.dwindle, route: "warm/rows/niri/tree-\(count)", report: false, expectedRows: 0)
        fixture.snapshot(.dwindle, route: "rows/niri/tree-\(count)", report: true, expectedRows: 0)
        guard count == limit else { return }
        fixture.populateSnapshotLayout(.dwindle)
        try await fixture.measureDecode(rows: count, of: ["dwindle"], reads: .dwindle)
    }
    let members = DwindleLayoutEngine.treeMemberLimit + 1
    let over = try ScriptARCFixture(
        directory: directory.appendingPathComponent("dwindle-over"),
        snapshotRows: 2 * members
    )
    defer {
        over.script.stop()
        for index in 0 ..< 2 * members {
            AXWindowService.invalidateCachedTitle(windowId: UInt32(over.token.windowId + index))
        }
    }
    _ = try await over.acceptTitleScript("omniwm.command('Inspect', function() end, {reads={'dwindle'}})")
    over.populateSnapshotLayout(.dwindle)
    precondition(over.controller.workspaceManager.tiledEntries(in: over.controller.activeWorkspace()!.id)
        .count == members)
    over.snapshot(.dwindle, route: "warm/rows/dwindle/over-cap", report: false, expectedRows: 0)
    over.snapshot(.dwindle, route: "rows/dwindle/over-cap", report: true, expectedRows: 0)
    let header = over.script.callbackQueue!.capture(reads: .dwindle, controller: over.controller).snapshot!
        .withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
    precondition(UInt8(truncatingIfNeeded: header >> 8) & UInt8(OMNI_CONFIG_SECTION_TRUNCATED) != 0)
}

@MainActor
extension ScriptARCFixture {
    fileprivate func treeCaptures(_ shape: String, count: Int, cold: Bool) {
        let route = "rows/dwindle/\(shape)-\(count)"
        snapshot(.dwindle, route: (cold ? "first/" : "warm/") + route, report: cold, expectedRows: 1)
        snapshot(.dwindle, route: route, report: true, expectedRows: 1)
        let manager = controller.workspaceManager
        let workspace = controller.activeWorkspace()!.id
        var nodes: [DwindleLayoutSnapshot.Node] = []
        manager.withEngineMutationScope(in: workspace) {
            nodes = manager.dwindleEngine!.layoutSnapshot(in: workspace)!.nodes
        }
        let splits = nodes.count { $0.orientation != nil }
        print("dwindle-shape \(route) splits=\(splits) leaves=\(nodes.count - splits)")
    }

    fileprivate func groupDwindleTiles() {
        let manager = controller.workspaceManager
        let engine = manager.dwindleEngine!
        let workspace = controller.activeWorkspace()!.id
        let tiled = manager.tiledEntries(in: workspace).map(\.token)
        manager.withEngineMutationScope(in: workspace) {
            for token in tiled.dropFirst() {
                precondition(engine.groupWindow(token, into: tiled[0], in: workspace))
            }
        }
        precondition(engine.existingState(for: workspace)?.tileCount == 1)
    }
}
