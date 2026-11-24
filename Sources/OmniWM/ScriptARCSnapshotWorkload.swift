// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ScriptARCCounters

@MainActor
extension ScriptARCFixture {
    private enum TextSource: Int, CaseIterable {
        case metadata
        case hosted
        case cache
        case foreign
    }

    static func admitSnapshotRows(
        _ count: Int, base: WindowToken, workspace: WorkspaceDescriptor.ID, controller: WMController
    ) throws {
        let manager = controller.workspaceManager
        let ax = AXUIElementCreateApplication(base.pid)
        controller.appInfoCache.evict(pid: base.pid)
        _ = controller.appInfoCache.info(for: base.pid) { _ in
            .init(name: nil, bundleId: "cached.app." + String(base.pid), icon: nil, activationPolicy: .regular)
        }
        controller.automationSessionToken = "Snapshot session 窓:" + String(base.pid)
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
func measureSnapshotRows(in directory: URL) async throws {
    for count in [ScriptARCFixture.workspaceRows, ScriptARCFixture.totalRows] {
        let fixture = try ScriptARCFixture(directory: directory, snapshotRows: count)
        defer {
            fixture.script.stop()
            for index in 0 ..< count {
                AXWindowService.invalidateCachedTitle(windowId: UInt32(fixture.token.windowId + index))
            }
        }
        _ = try await fixture
            .acceptTitleScript("omniwm.command('Inspect', function() end, {reads={'windows', 'workspaceWindows'}})")
        for layout in [LayoutType.niri, .dwindle] {
            fixture.populateSnapshotLayout(layout)
            for (name, reads) in [("workspace", ConfigScriptReads.workspaceWindows), ("windows", .windows)] {
                let route = "rows/\(layout.rawValue)/\(name)-\(count)"
                fixture.snapshot(reads, route: "first/" + route, report: layout == .niri, expectedRows: count)
                fixture.snapshot(reads, route: route, report: true, expectedRows: count)
            }
        }
    }
}
