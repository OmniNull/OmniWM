// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
import ScriptARCCounters

@MainActor
func measureOrdinaryNiriReconcile(in directory: URL) throws {
    for mode in OrdinaryNiriReconcileFixture.Mode.allCases {
        let route = "reconcile/" + mode.rawValue
        let controller = OrdinaryNiriReconcileFixture.makeController(
            in: directory.appendingPathComponent(route)
        )
        defer {
            controller.layoutRefreshController.resetState()
            controller.mouseEventHandler.cleanup()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
        }
        let fixture = try OrdinaryNiriReconcileFixture(controller: controller, mode: mode)
        let manager = controller.workspaceManager
        fixture.reconcile()
        let settled = manager.niriViewportState(for: fixture.workspace)
        fixture.reconcile()
        precondition(manager.niriViewportState(for: fixture.workspace) == settled)

        script_arc_begin()
        let plans = fixture.reconcile()
        script_arc_end()

        precondition(plans.count == fixture.workspaceScope.count)
        precondition(manager.niriViewportState(for: fixture.workspace) == settled)
        script_arc_report(route, "native", 0)
    }
}

@MainActor
private struct OrdinaryNiriReconcileFixture {
    enum Mode: String, CaseIterable {
        case single
        case packed
        case excluded
        case centered
    }

    let controller: WMController
    let workspace: WorkspaceDescriptor.ID
    let workspaceScope: Set<WorkspaceDescriptor.ID>

    init(controller: WMController, mode: Mode) throws {
        let displayID: CGDirectDisplayID = 95_200
        let displayBounds = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let monitor = Monitor(
            id: .init(displayId: displayID),
            displayId: displayID,
            frame: displayBounds,
            visibleFrame: displayBounds,
            hasNotch: false,
            name: "Viewport Reconcile"
        )
        controller.motionPolicy.animationsEnabled = false
        controller.settings.borders.enabled = false
        controller.settings.workspaceBar.enabled = false
        controller.settings.niri.shrinkToFit = false
        controller.settings.niri.centerFocusedColumn = mode == .centered ? .always : .never
        controller.layoutRefreshController.layoutState.backingScaleByDisplay = [displayID: 2]

        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        guard let workspace = manager.workspaceId(for: "1", createIfMissing: true) else {
            throw ScriptARCError("Missing Niri reconcile workspace")
        }
        _ = manager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        guard let engine = controller.niriEngine else { throw ScriptARCError("Missing Niri engine") }
        self.controller = controller
        self.workspace = workspace
        workspaceScope = [workspace]

        trackWindows(count: mode == .single ? 1 : 5)
        reconcile()
        if mode != .single { try packAndSelect(engine: engine, minimized: mode == .excluded) }
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
    }

    static func makeController(in directory: URL) -> WMController {
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: directory.appendingPathComponent("config"),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        let controller = WMController(
            settings: settings,
            clipboardHistoryDirectory: directory,
            diagnosticsDirectory: directory,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let handler = controller.axEventHandler
        handler.lifecycleQueries.query = { [weak handler] in handler?.windowInfoProvider($0) }
        handler.frameObservations.nativeDragQuery = { [weak handler] in handler?.windowInfoProvider($0) }
        return controller
    }

    @discardableResult
    func reconcile() -> [WorkspaceLayoutPlan] {
        controller.layoutRefreshController.buildWorkspacePlansInBatch {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: workspaceScope)
        }
    }

    private func trackWindows(count: Int) {
        let manager = controller.workspaceManager
        let pid: pid_t = 95_201
        for index in 0 ..< count {
            let token = WindowToken(pid: pid, windowId: Int(pid) + index)
            let ref = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: token.windowId)
            _ = manager.addWindow(ref, pid: pid, windowId: token.windowId, to: workspace)
            manager.setCachedConstraints(.unconstrained, for: token)
        }
    }

    private func packAndSelect(engine: NiriLayoutEngine, minimized: Bool) throws {
        let manager = controller.workspaceManager
        let columns = engine.columns(in: workspace)
        let activeIndex = columns.startIndex + 1
        let nextIndex = activeIndex + 1
        guard columns.indices.contains(nextIndex),
              let active = columns[activeIndex].windowNodes.first,
              let member = columns[nextIndex].windowNodes.first,
              let excluded = columns.last?.windowNodes.first
        else { throw ScriptARCError("Missing columns in the reconcile fixture") }
        manager.withEngineMutationScope(in: workspace) {
            engine.moveWindowToColumn(member, from: columns[nextIndex], to: columns[activeIndex], in: workspace)
            columns[nextIndex].remove()
        }
        precondition(engine.columns(in: workspace).count == columns.count - 1)
        manager.withNiriViewportState(for: workspace) {
            $0.activeColumnIndex = activeIndex
            $0.selectedNodeId = active.id
        }
        _ = manager.commitWorkspaceSelection(nodeId: active.id, focusedToken: active.token, in: workspace)
        if minimized {
            let changed = manager.setWindowMinimized(true, token: excluded.token)
            precondition(changed)
        }
    }
}
