// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import ScriptARCCounters

@MainActor
func measureLayoutChanged(in directory: URL, dormantOnly: Bool = false) async throws {
    for tabbed in [false, true] {
        let location = directory.appendingPathComponent(tabbed ? "layout-tabbed" : "layout-stacked")
        let audit = try LayoutChangedAudit(in: location, tabbed: tabbed)
        defer { audit.close() }
        audit.measureDormant()
        if !dormantOnly { try await audit.measureSubscribed() }
    }
}

@MainActor
private final class LayoutChangedAudit {
    private static let event = "layout.changed"
    private static let windowCount = 4
    private static let emptyWorkspaceName = "2"
    private let fixture: ScriptARCFixture
    private let workspace: WorkspaceDescriptor.ID
    private let emptyWorkspace: WorkspaceDescriptor.ID
    private let engine: NiriLayoutEngine
    private let workingWidth: CGFloat
    private let tabbed: Bool

    private var controller: WMController {
        fixture.controller
    }

    private var reconciler: SurfaceReconciler {
        controller.surfaceReconciler
    }

    init(in directory: URL, tabbed: Bool) throws {
        self.tabbed = tabbed
        let fixture = try ScriptARCFixture(directory: directory, snapshotRows: Self.windowCount)
        self.fixture = fixture
        let controller = fixture.controller
        let manager = controller.workspaceManager
        controller.settings.borders.enabled = true
        controller.settings.island.enabled = false
        controller.layoutRefreshController.layoutState.isRefreshSuspendedForLockScreen = true
        guard let workspace = manager.workspace(for: fixture.token),
              let monitor = manager.monitor(for: workspace),
              let empty = manager.workspaceId(for: Self.emptyWorkspaceName, createIfMissing: false)
        else { throw ScriptARCError("Missing layout event fixture workspaces") }
        self.workspace = workspace
        emptyWorkspace = empty
        controller.layoutRefreshController.layoutState.backingScaleByDisplay = [monitor.displayId: monitor.backingScale]
        _ = manager.clearNativeFocusOwner()
        let fixtureSpace = UInt64(monitor.displayId)
        manager.commitSpaceTopology(SpaceTopology(
            displays: [.init(
                displayIdentifier: monitor.displayUUID ?? String(monitor.displayId),
                spaceIds: [fixtureSpace],
                currentSpaceId: fixtureSpace
            )],
            activeSpaceId: fixtureSpace,
            fullscreenSpaceIds: [fixtureSpace]
        ))
        controller.enableNiriLayout()
        guard let engine = controller.niriEngine else { throw ScriptARCError("Missing layout event fixture engine") }
        self.engine = engine
        workingWidth = controller.niriInteractionGeometry(for: monitor).workingFrame.width
        seedColumns(tabbed: tabbed)
        controller.hasStartedServices = true
        reconciler.controller = controller
        reconciler.noteWorldChanged()
        reconciler.reconcileNow()
        let scene = reconciler.appliedScene
        precondition(scene.border == nil && scene.parkingEdgeMasks.isEmpty && scene.placeholders.isEmpty)
        precondition(scene.bars.isEmpty && scene.islands.isEmpty)
        precondition(scene.tabRails.isEmpty != tabbed)
        precondition(scene.tabRails.allSatisfy { rail in
            !TabRailManager.isRenderable(visibleTileFrame: rail.visibleTileFrame)
                && controller.tabRailManager.existingWindow(for: rail.key) == nil
                && rail.tabs.allSatisfy { $0.icon == nil }
        })
    }

    private func seedColumns(tabbed: Bool) {
        let manager = controller.workspaceManager
        let tokens = (0 ..< Self.windowCount).map {
            WindowToken(pid: fixture.token.pid, windowId: fixture.token.windowId + $0)
        }
        for token in tokens {
            _ = manager.setWindowMode(.tiling, for: token)
            if let id = UInt32(exactly: token.windowId) {
                AXWindowService.storeTitleCacheEntry(windowId: id, title: "Layout audit")
            }
        }
        let columnWidth = workingWidth / CGFloat(Self.windowCount - 1)
        manager.withEngineMutationScope(in: workspace) {
            for token in tokens {
                let window = engine.addWindow(token: token, to: workspace, afterSelection: nil)
                let column = engine.column(of: window)!
                column.width = .fixed(columnWidth)
                column.cachedWidth = columnWidth
            }
            if tabbed {
                controller.appInfoCache.evict(pid: fixture.token.pid)
                _ = controller.appInfoCache.info(for: fixture.token.pid) { _ in
                    .init(name: nil, bundleId: "layout.audit", icon: nil, activationPolicy: .regular)
                }
                let cachedToken = fixture.snapshotCachedTitleToken
                guard let firstEntry = manager.entry(for: fixture.token), firstEntry.target.hostedMetadata == nil,
                      let cachedEntry = manager.entry(for: cachedToken), cachedEntry.target.hostedMetadata == nil,
                      let firstWindow = engine.findNode(for: fixture.token, in: workspace),
                      let first = engine.column(of: firstWindow),
                      let cachedWindow = engine.findNode(for: cachedToken, in: workspace),
                      let cachedColumn = engine.column(of: cachedWindow)
                else { preconditionFailure("Missing native tabs for the layout audit") }
                first.appendChild(cachedWindow)
                cachedColumn.remove()
                first.displayMode = .tabbed
                first.setActiveTileIdx(0)
            }
        }
    }

    func close() {
        fixture.script.stop()
        controller.hasStartedServices = false
        reconciler.cleanup()
        reconciler.controller = nil
        controller.layoutRefreshController.resetState()
        controller.axEventHandler.cleanup()
        controller.axManager.cleanup()
    }

    func measureDormant() {
        if tabbed {
            measureIdleScene("layout/interactive-tabbed-dormant", invalidation: .layoutEdge, scope: .fullScene)
        } else {
            measureIdleScene("layout/dormant-full", invalidation: .full, scope: .fullScene)
            measureIdleScene("layout/interactive-dormant", invalidation: .layoutEdge, scope: .borderOnly)
            measureTick("layout/dormant-tick")
        }
        precondition(reconciler.appliedScene.niriColumns.isEmpty)
    }

    func measureSubscribed() async throws {
        let queue = try await fixture.acceptTitleScript("""
        omniwm.on("\(Self.event)", function(e)
            assert(e.workspaces == nil and e.windows == nil and e.truncated == nil and e.missed == nil)
        end)
        """)
        await queue.waitForAuditPark()
        reconciler.reconcileNow()
        precondition(queue.isParked && !queue.hasPendingWork)
        precondition(reconciler.appliedScene.niriColumns[workspace] != nil && reconciler.appliedScene.bars.isEmpty)
        if tabbed {
            measureIdleScene(
                "layout/interactive-tabbed-subscribed", invalidation: .layoutEdge, scope: .fullScene,
                control: "layout/interactive-tabbed-dormant"
            )
            measureSummary()
            return
        }
        measureIdleScene("layout/unchanged", invalidation: .full, scope: .fullScene, control: "layout/dormant-full")
        measureIdleScene(
            "layout/interactive-subscribed", invalidation: .layoutEdge, scope: .fullScene,
            control: "layout/interactive-dormant"
        )
        measureTick("layout/subscribed-tick", control: "layout/dormant-tick")
        measureSummary()
        try await measureEnqueue()
        try await measureChanges()
    }

    private func measureIdleScene(
        _ route: String, invalidation: SessionSurfaceInvalidationScope, scope: SurfaceReconciler.ReconcileScope,
        control: String = "native"
    ) {
        reconcile(invalidation, scope: scope, measured: false)
        reconcile(invalidation, scope: scope, measured: true)
        precondition(fixture.script.callbackQueue?.hasPendingWork != true)
        script_arc_report(route, control, 0)
    }

    private func reconcile(
        _ invalidation: SessionSurfaceInvalidationScope, scope: SurfaceReconciler.ReconcileScope, measured: Bool
    ) {
        let reconciler = reconciler
        if measured { script_arc_begin() }
        reconciler.noteInvalidation(invalidation)
        let chosen = reconciler.pendingReconcileScope
        reconciler.reconcileNow()
        if measured { script_arc_end() }
        precondition(chosen == scope && reconciler.appliedScene.bars.isEmpty)
    }

    private func measureTick(_ route: String, control: String = "native") {
        let reconciler = reconciler
        reconciler.reconcileAnimationTick()
        script_arc_begin()
        reconciler.reconcileAnimationTick()
        script_arc_end()
        precondition(fixture.script.callbackQueue?.hasPendingWork != true)
        script_arc_report(route, control, 0)
    }

    private func measureSummary() {
        let route = tabbed ? "layout/summary-tabbed" : "layout/summary"
        let world = WorldView(controller: controller)
        for report in [false, true] {
            if report { script_arc_begin() }
            let summaries = world.niriColumnSummaries()
            if report { script_arc_end() }
            precondition(summaries[workspace]?.columnIndexByToken.count == Self.windowCount)
            withUnsafePointer(to: summaries) { script_arc_sink($0) }
            if report { script_arc_report(route, "native", 0) }
        }
    }

    private func measureEnqueue() async throws {
        guard let kind = ConfigScriptEventKind(rawValue: Self.event) else {
            throw ScriptARCError("Missing layout event kind")
        }
        let controller = controller
        for report in [false, true] {
            var queue = fixture.script.callbackQueue
            if report { script_arc_begin() }
            ConfigScriptCallbackQueue.publish(kind, .init(), in: &queue, controller: controller)
            if report { script_arc_end() }
            precondition(queue?.hasPendingWork == true)
            try await fixture.finishWorker(seed: false)
            if report { script_arc_report("layout/enqueue", "native", 1) }
        }
    }

    private func measureChanges() async throws {
        let manager = controller.workspaceManager
        let columns = engine.columns(in: workspace)
        let last = columns[columns.index(before: columns.endIndex)]
        let previous = columns[columns.index(columns.endIndex, offsetBy: -2)]
        for report in [false, true] {
            let old = reconciler.appliedScene.niriColumns[workspace]!
            manager.withEngineMutationScope(in: workspace) { last.swapWith(previous) }
            try await measureChange("layout/renumber", invalidation: .layoutEdge, report: report)
            let new = reconciler.appliedScene.niriColumns[workspace]!
            precondition(old.columnIndexByToken != new.columnIndexByToken)
            precondition(old.viewport == new.viewport && old.displayModes == new.displayModes)
        }
        try await measureViewportChanges()
        try await measureLayoutSwitch()
    }

    private func measureViewportChanges() async throws {
        for offset in [workingWidth, 0] {
            let old = reconciler.appliedScene.niriColumns[workspace]!
            controller.workspaceManager.withNiriViewportState(for: workspace) { $0.viewOffset = offset }
            try await measureChange("layout/viewport", invalidation: .layoutEdge, report: offset == 0)
            let new = reconciler.appliedScene.niriColumns[workspace]!
            precondition(old.columnIndexByToken == new.columnIndexByToken && old.viewport != new.viewport)
            precondition(old.displayModes == new.displayModes)
        }
    }

    private func measureLayoutSwitch() async throws {
        for layout in [LayoutType.dwindle, .niri] {
            let result = controller.commandHandler.setWorkspaceLayout(
                layout,
                forWorkspaceNamed: Self.emptyWorkspaceName
            )
            precondition(result == .executed)
            try await measureChange("layout/layout-only", invalidation: .full, report: layout == .niri)
            let summary = reconciler.appliedScene.niriColumns[emptyWorkspace]
            if layout == .niri { precondition(summary?.columnIndexByToken.isEmpty == true) }
            else { precondition(summary == nil) }
        }
    }

    private func measureChange(
        _ route: String, invalidation: SessionSurfaceInvalidationScope, report: Bool
    ) async throws {
        reconcile(invalidation, scope: .fullScene, measured: report)
        precondition(fixture.script.callbackQueue?.hasPendingWork == true)
        try await fixture.finishWorker(seed: false)
        if report {
            let control = invalidation == .full ? "layout/unchanged" : "layout/interactive-subscribed"
            script_arc_report(route, control, 1)
        }
    }
}
