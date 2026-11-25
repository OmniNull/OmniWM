// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMScriptHost
import ScriptARCCounters

@MainActor
extension ScriptARCFixture {
    private enum TextSource: Int, CaseIterable {
        case metadata
        case hosted
        case cache
        case foreign
    }

    static let snapshotRoutes: [(name: String, reads: ConfigScriptReads)] = [
        ("workspace", .workspaceWindows),
        ("windows", .windows),
        ("framed", [.workspaceWindows, .windows, .monitors, .workspaceWindowFrames, .windowFrames, .monitorFrames])
    ]

    static func admitSnapshotRows(
        _ count: Int, base: WindowToken, workspace: WorkspaceDescriptor.ID, controller: WMController
    ) throws {
        let manager = controller.workspaceManager
        let ax = AXUIElementCreateApplication(base.pid)
        controller.appInfoCache.evict(pid: base.pid)
        _ = controller.appInfoCache.info(for: base.pid) { _ in
            .init(name: nil, bundleId: "cached.app." + String(base.pid), icon: nil, activationPolicy: .regular)
        }
        for index in 0 ..< count {
            let token = WindowToken(pid: base.pid, windowId: base.windowId + index)
            let bundle = "app.with.a.dynamic.bundle.id." + String(index)
            let title = "Snapshot fixture 窓 № " + String(index)
            let source = TextSource.allCases[index % TextSource.allCases.count]
            let admitted: WindowToken?
            if source == .hosted {
                let size = CGSize(width: 100, height: 100)
                admitted = manager.addHostedWindow(
                    token: token, metadata: .init(appId: bundle, title: title, minimumSize: size),
                    to: workspace, initialFrame: CGRect(origin: .zero, size: size)
                )
            } else {
                let mode: TrackedWindowMode = index.isMultiple(of: 2) ? .floating : .tiling
                if source == .cache { AXWindowService.storeTitleCacheEntry(
                    windowId: UInt32(token.windowId),
                    title: title
                ) }
                let text = source == .foreign ? Array(title.utf16).withUnsafeBufferPointer {
                    NSString(characters: $0.baseAddress!, length: $0.count) as String
                } : title
                if source == .foreign { precondition(text.utf8.withContiguousStorageIfAvailable { _ in true } == nil) }
                let metadata: ManagedReplacementMetadata? = source == .cache ? nil :
                    .init(bundleId: bundle, workspaceId: workspace, mode: mode, title: text)
                admitted = manager.addWindow(
                    AXWindowRef(element: ax, windowId: token.windowId), pid: token.pid, windowId: token.windowId,
                    to: workspace, mode: mode, managedReplacementMetadata: metadata
                )
            }
            guard admitted == token else { throw ScriptARCError("Missing snapshot fixture window") }
        }
    }

    func seedSnapshotFrames(_ count: Int) {
        let manager = controller.workspaceManager
        let frame = CGRect(origin: .zero, size: manager.monitors[0].visibleFrame.size)
        for index in 0 ..< count {
            let row = WindowToken(pid: token.pid, windowId: token.windowId + index)
            if manager.windowMode(for: row) == .floating {
                manager.updateFloatingGeometry(frame: frame, for: row)
            } else {
                controller.axManager.confirmFrameWrite(for: row.windowId, frame: frame)
            }
        }
    }

    func measureDecode(rows: Int, of modifiers: [String], reads: ConfigScriptReads) async throws {
        let words = (["windows"] + modifiers).map { "\"" + $0 + "\"" }.joined(separator: ", ")
        let evaluation = try await loader.evaluate(Data("""
        omniwm.on("workspace.active", function(e) assert(#e.windows == \(rows)) end, { reads = { "windows" } })
        omniwm.on("workspace.active", function(e) assert(#e.windows == \(rows)) end, { reads = { \(words) } })
        """.utf8), hyperMask: 0)
        guard let generation = evaluation.generation, let queue = script.callbackQueue,
              let plain = queue.capture(reads: .windows, controller: controller).snapshot,
              let modified = queue.capture(reads: reads.union(.windows), controller: controller).snapshot
        else { throw ScriptARCError("Missing decode fixture") }
        let payload = ConfigScriptEventPayload(name: "decode")
        let label = modifiers.joined(separator: "+")
        for (name, listener, snapshot) in [("off", 0, plain), ("skipped", 0, modified), ("on", 1, modified)] {
            let function = evaluation.events[listener].function
            _ = try await generation.invoke(function: function, event: payload, snapshot: snapshot)
            var samples: [Double] = []
            samples.reserveCapacity(Self.decodeSamples)
            for _ in 0 ..< Self.decodeSamples {
                let start = ContinuousClock.now
                _ = try await generation.invoke(function: function, event: payload, snapshot: snapshot)
                samples.append((ContinuousClock.now - start) / .nanoseconds(1))
            }
            samples.sort()
            print("decode/windows-\(rows) \(label)=\(name) median-ns=\(Int(samples[samples.count / 2]))")
        }
    }

    func populateSnapshotLayout(_ layout: LayoutType) {
        let manager = controller.workspaceManager
        let workspace = controller.activeWorkspace()!
        let settings = controller.settings.workspaces
        let index = settings.configurations.firstIndex { $0.name == workspace.name }!
        settings.configurations[index].layoutType = layout
        let tiled = manager.tiledEntries(in: workspace.id).map(\.token)
        switch layout {
        case .niri:
            let engine = NiriLayoutEngine()
            manager.niriEngine = engine
            manager.withEngineMutationScope(in: workspace.id) {
                _ = engine.syncWindows(tiled, in: workspace.id, selectedNodeId: nil)
            }
            _ = engine.projectedColumns(in: workspace.id)
        case .dwindle:
            let engine = DwindleLayoutEngine()
            manager.dwindleEngine = engine
            manager.withEngineMutationScope(in: workspace.id) {
                _ = engine.syncWindows(tiled, in: workspace.id, focusedToken: nil)
            }
        default: preconditionFailure()
        }
    }
}

@MainActor
package func runScriptARCSnapshotLifetime(directory: URL) async throws {
    let fixture = try ScriptARCFixture(directory: directory, snapshotRows: ScriptARCFixture.workspaceRows)
    defer {
        for index in 0 ..< ScriptARCFixture.workspaceRows {
            AXWindowService.invalidateCachedTitle(windowId: UInt32(fixture.token.windowId + index))
        }
    }
    let source = """
    omniwm.command("Read", function(c)
        assert(#c.workspaceWindows == \(ScriptARCFixture.workspaceRows))
        for i, row in c.workspaceWindows do
            assert(row.title == "Snapshot fixture 窓 № " .. (i - 1) and row.bundleId)
        end
    end, {reads={"workspaceWindows"}})
    """
    let queue = try await fixture.acceptTitleScript(source)
    let controller = fixture.controller
    let reads = ConfigScriptReads.workspaceWindows
    func capture() -> ConfigScriptSnapshot {
        queue.capture(reads: reads, controller: controller).snapshot!
    }
    func address(_ snapshot: ConfigScriptSnapshot) -> UInt {
        snapshot.withUnsafeBytes { UInt(bitPattern: $0.baseAddress!) }
    }
    func contents(_ snapshot: ConfigScriptSnapshot) -> [UInt8] {
        snapshot.withUnsafeBytes { Array($0) }
    }
    var first: ConfigScriptSnapshot? = capture()
    let expected = contents(first!)
    let original = address(first!)
    await fixture.holdInFlight("Read")
    fixture.enqueue("Read")
    _ = controller.workspaceManager.updateManagedReplacementTitle("Updated after enqueue", for: fixture.token)
    let second = capture()
    precondition(address(second) != original)
    precondition(contents(second) != expected && contents(first!) == expected)
    script_arc_release_entry()
    await queue.waitForAuditPark()
    script_arc_finish_entry()
    precondition(fixture.script.diagnostic == nil)
    first = nil
    let reused = capture()
    precondition(address(reused) == original && contents(reused) == contents(second))
    fixture.script.stop()
    let replacement = try await fixture.acceptTitleScript(source)
    let next = replacement.capture(reads: reads, controller: controller).snapshot!
    precondition(address(next) != original && contents(next) == contents(reused))
    fixture.script.stop()
    withExtendedLifetime((second, reused, next)) {}
    print("snapshot lifetime passed: in-flight and queued reads, held and reused storage, retirement and replacement")
}

@MainActor
func measureSnapshotRows(
    in directory: URL, counts: [Int] = [ScriptARCFixture.workspaceRows, ScriptARCFixture.totalRows],
    routes: [(name: String, reads: ConfigScriptReads)] = ScriptARCFixture.snapshotRoutes,
    after: (ScriptARCFixture, Int) async throws -> Void = { _, _ in }
) async throws {
    for count in counts {
        let fixture = try ScriptARCFixture(directory: directory, snapshotRows: count)
        defer {
            fixture.script.stop()
            for index in 0 ..< count {
                AXWindowService.invalidateCachedTitle(windowId: UInt32(fixture.token.windowId + index))
            }
        }
        fixture.seedSnapshotFrames(count)
        _ = try await fixture
            .acceptTitleScript("omniwm.command('Inspect', function() end, {reads={'windows', 'workspaceWindows'}})")
        for layout in [LayoutType.niri, .dwindle] {
            fixture.populateSnapshotLayout(layout)
            for (name, reads) in routes {
                let route = "rows/\(layout.rawValue)/\(name)-\(count)"
                fixture.snapshot(reads, route: "first/" + route, report: layout == .niri, expectedRows: count)
                fixture.snapshot(reads, route: route, report: true, expectedRows: count)
            }
        }
        try await after(fixture, count)
    }
}

@MainActor
func measureMixedFrames(in directory: URL) async throws {
    let fixture = try ScriptARCFixture(directory: directory.appendingPathComponent("mixed-frames"))
    fixture.seedSnapshotFrames(ScriptARCFixture.workspaceRows)
    try await fixture.mixedReads(
        "frames", probe: "e.windows[1].frame", rows: "#e.windows == \(ScriptARCFixture.totalRows)",
        routes: ["shared-frames", "shared-plain", "solo-frames", "solo-plain"]
    )
}

@MainActor
func measureColumnReads(in directory: URL) async throws {
    let mixed = try ScriptARCFixture(directory: directory.appendingPathComponent("mixed-columns"))
    mixed.populateSnapshotLayout(.niri)
    mixed.fillWindowList()
    try await mixed.mixedReads(
        "columns", probe: "e.windows[2].column",
        rows: "#e.windows == \(ScriptARCFixture.totalRows) and e.truncated.windows == false",
        routes: ["shared-columns", "shared-plain-columns", "solo-columns", "solo-plain-columns"]
    )
    let limit = ConfigScriptSnapshot.rowLimit
    try await measureSnapshotRows(
        in: directory.appendingPathComponent("column-rows"),
        counts: [ScriptARCFixture.workspaceRows, ScriptARCFixture.totalRows, limit],
        routes: [("columned", [.workspaceWindows, .windows, .workspaceWindowColumns, .windowColumns])]
    ) { fixture, count in
        fixture.populateSnapshotLayout(.niri)
        if count == ScriptARCFixture.totalRows { fixture.columnEdits() }
        guard count == limit else { return }
        try await fixture.measureDecode(rows: count, of: ["columns"], reads: .windowColumns)
        try await fixture.measureDecode(rows: count, of: ["frames", "columns"], reads: [.windowFrames, .windowColumns])
    }
}

@MainActor
func measureFocusTarget(in directory: URL) async throws {
    let fixture = try ScriptARCFixture(directory: directory.appendingPathComponent("focus-target"))
    try await fixture.focusTarget()
}

@MainActor
extension ScriptARCFixture {
    fileprivate func focusTarget() async throws {
        let manager = controller.workspaceManager
        let workspace = manager.workspace(for: token)!
        let name = manager.descriptor(for: workspace)!.name
        let queue = try await acceptTitleScript("""
        omniwm.on("workspace.active", function(e)
            local t = e.focusTarget
            assert(t and e.id and t.nativeFullscreen == false)
            omniwm.dispatch("window", "focus", t.id, { targetOf = e.id, nativeFullscreen = true })
        end, { reads = { "focusTarget" } })
        """)
        await queue.waitForAuditPark()
        for report in [false, true] {
            focusTargetCapture([], route: "capture/no-focus-target", report: report)
        }
        try await focusTargetRoutes("focus-target", expecting: token, in: workspace, name: name)
        precondition(manager.markNativeFullscreenSuspended(token, ownsNativeFocus: false))
        precondition(manager.requestNativeFullscreenExit(token))
        precondition(manager.nativeFullscreenRecord(for: token)?.transition == .exitRequested)
        try await focusTargetRoutes("focus-target-exit", expecting: token, in: workspace, name: name)
        precondition(manager.restoreNativeFullscreenRecord(for: token, clearsNativeFocusOwner: false))
        precondition(manager.setWindowMinimized(true, token: token))
        try await focusTargetRoutes("focus-target-fallback", expecting: otherWindow, in: workspace, name: name)
    }

    fileprivate func fillWindowList() {
        let manager = controller.workspaceManager
        var pool = ConfigScriptSnapshotPool()
        func header() -> UInt64 {
            controller.configScriptSnapshot(reads: .windows, target: controller.configScriptTarget(), pool: &pool)
                .withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        }
        func used(_ header: UInt64) -> Int {
            MemoryLayout<UInt64>.size + Int(truncatingIfNeeded: header >> 32)
        }
        let last = WindowToken(pid: token.pid, windowId: token.windowId + Self.totalRows - 1)
        let title = manager.windowQueries.managedReplacementMetadata(for: last)?.title ?? ""
        let missing = ConfigScriptSnapshot.byteLimit - used(header())
        precondition(manager.updateManagedReplacementTitle(title + String(repeating: "x", count: missing), for: last))
        let full = header()
        precondition(used(full) == ConfigScriptSnapshot.byteLimit && UInt16(truncatingIfNeeded: full >> 16) == Self
            .totalRows)
        precondition(UInt8(truncatingIfNeeded: full >> 8) & UInt8(OMNI_CONFIG_SECTION_TRUNCATED) == 0)
    }

    fileprivate func columnEdits() {
        let manager = controller.workspaceManager
        let engine = manager.niriEngine!
        let workspace = controller.activeWorkspace()!.id
        let tiled = manager.tiledEntries(in: workspace).compactMap { entry -> WindowToken? in
            if case .hosted = entry.target { return nil }
            return entry.token
        }
        let reads: ConfigScriptReads = [.workspaceWindows, .workspaceWindowColumns]
        let target = engine.findNode(for: tiled[0], in: workspace).flatMap(engine.column(of:))!
        snapshot(reads, route: "warm/columns-edit", report: false)
        join(tiled[1], into: target, reads: reads, routes: (
            "capture/columns-after-edit",
            "engine/projection-rebuild"
        )) {
            withExtendedLifetime($0.projectedColumns) {}
        }
        heldTabCaptures(anchor: tiled[0], in: target, reads: reads)
        snapshot(reads, route: "warm/columns-plain", report: false)
        precondition(engine.root(for: workspace)!.cachedProjectedColumns != nil)
        precondition(manager.setWindowMinimized(true, token: tiled[2]))
        precondition(engine.root(for: workspace)!.cachedProjectedColumns != nil)
        for report in [false, true] {
            snapshot(reads, route: "capture/columns-excluded", report: report)
        }
        join(
            tiled[3], into: target, reads: reads,
            routes: ("capture/columns-after-edit-excluded", "engine/columns-rebuild")
        ) { root in
            for column in root.columns {
                withExtendedLifetime(column.windowNodes) {}
            }
        }
    }

    private func join(
        _ window: WindowToken, into target: NiriContainer, reads: ConfigScriptReads,
        routes: (capture: String, rebuild: String), rebuild: (NiriRoot) -> Void
    ) {
        let manager = controller.workspaceManager
        let engine = manager.niriEngine!
        let workspace = controller.activeWorkspace()!.id
        let node = engine.findNode(for: window, in: workspace)!
        let source = engine.column(of: node)!
        manager.withEngineMutationScope(in: workspace) {
            engine.moveWindowToColumn(node, from: source, to: target, in: workspace)
            source.remove()
        }
        snapshot(reads, route: routes.capture, report: true)
        target.invalidateChildrenCache()
        let root = engine.root(for: workspace)!
        script_arc_begin()
        rebuild(root)
        script_arc_end()
        script_arc_report(routes.rebuild, "capture/fixed", 0)
    }

    private func heldTabCaptures(anchor: WindowToken, in target: NiriContainer, reads: ConfigScriptReads) {
        let manager = controller.workspaceManager
        let engine = manager.niriEngine!
        let workspace = controller.activeWorkspace()!.id
        let node = engine.findNode(for: anchor, in: workspace)!
        let monitor = manager.monitor(for: workspace)!
        let context = NiriInteractionContext(
            workspaceId: workspace, motion: .disabled, workingFrame: controller.niriWorkingFrame(for: monitor),
            gaps: controller.innerGap(for: monitor), orientation: .horizontal
        )
        manager.withEngineMutationScope(in: workspace) {
            target.displayMode = .tabbed
            manager.withNiriViewportState(for: workspace) { state in
                precondition(engine.liveColumnMoveBegin(
                    windowId: node.id, windowToken: anchor, context: context, state: &state
                ))
            }
            engine.liveColumnMove?.heldTabs = target.windowNodes.filter { $0 !== node }
        }
        precondition(engine.liveColumnMove?.heldTabs.isEmpty == false)
        for report in [false, true] {
            snapshot(reads, route: "capture/columns-held-tab", report: report)
        }
        manager.withEngineMutationScope(in: workspace) {
            engine.liveColumnMove = nil
            target.displayMode = .normal
        }
    }

    func mixedReads(_ modifier: String, probe: String, rows: String, routes: [String]) async throws {
        let manager = controller.workspaceManager
        let workspace = manager.workspace(for: token)!
        let name = manager.descriptor(for: workspace)!.name
        let plainListener = """
        omniwm.on("workspace.active", function(e)
            assert(\(rows) and \(probe) == nil)
        end, { reads = { "windows" } })
        """
        for (route, (modified, shared)) in zip(routes, [(true, true), (false, true), (true, false), (false, false)]) {
            let reads = modified ? "\"windows\", \"\(modifier)\"" : "\"windows\""
            let queue = try await acceptTitleScript("""
            omniwm.on("workspace.active", function(e)
                assert(\(rows) and (\(probe) ~= nil) == \(modified))
            end, { reads = { \(reads) } })
            \(shared ? plainListener : "")
            """)
            await queue.waitForAuditPark()
            for report in [false, true] {
                workspaceActive(workspace, name: name)
                try await finishWorker(seed: false)
                if report {
                    script_arc_report("event/workspace.active+" + route, "event/workspace.active", shared ? 2 : 1)
                }
            }
        }
    }

    private func focusTargetRoutes(
        _ route: String, expecting target: WindowToken, in workspace: WorkspaceDescriptor.ID, name: String
    ) async throws {
        let manager = controller.workspaceManager
        precondition(manager.resolveWorkspaceFocusToken(in: workspace) == target)
        for report in [false, true] {
            focusTargetCapture(.focusTarget, route: "capture/" + route, report: report)
            workspaceActive(workspace, name: name)
            try await finishWorker(seed: false)
            if report { script_arc_report("event/workspace.active+" + route, "event/workspace.active", 1) }
            precondition(manager.resolveWorkspaceFocusToken(in: workspace) == target)
        }
    }

    @inline(never)
    private func workspaceActive(_ workspace: WorkspaceDescriptor.ID, name: String) {
        let controller = controller
        script_arc_begin()
        ConfigScriptEventObservers.workspaceChanged(workspace, name: name, controller: controller)
        script_arc_end()
    }

    @inline(never)
    private func focusTargetCapture(_ reads: ConfigScriptReads, route: String, report: Bool) {
        let queue = script.callbackQueue!
        script_arc_begin()
        let capture = queue.capture(reads: reads, controller: controller)
        script_arc_end()
        if report {
            script_arc_report(route, "capture/fixed", 0)
            print("snapshot-bytes \(route) \(capture.snapshot?.withUnsafeBytes(\.count) ?? 0)")
        }
        withUnsafePointer(to: capture) { script_arc_sink($0) }
        guard let snapshot = capture.snapshot else { return precondition(reads.isEmpty) }
        snapshot.withUnsafeBytes { bytes in
            let header = bytes.loadUnaligned(as: UInt64.self).littleEndian
            precondition(UInt16(truncatingIfNeeded: header >> 16) == 1)
        }
    }
}
