// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
struct MonitorConfigurationHandler {
    private weak var controller: WMController?
    private let inventory: NativeSpaceInventoryController
    private var displayObserver: DisplayConfigurationObserver?
    var currentMonitorsProvider: @MainActor () -> [Monitor] = { Monitor.current() }

    init(controller: WMController, inventory: NativeSpaceInventoryController) {
        self.controller = controller
        self.inventory = inventory
    }

    mutating func stopObserving() {
        displayObserver = nil
    }

    mutating func startObserving() {
        guard let controller else { return }
        let observer = DisplayConfigurationObserver(
            initialMonitors: controller.workspaceManager.monitors,
            monitorSampler: currentMonitorsProvider
        )
        observer.setEventHandler { event in
            EventIntake.post(.display(event))
        }
        displayObserver = observer
        observer.sampleNow()
    }

    func handle(_ event: DisplayConfigurationObserver.DisplayEvent) {
        let currentMonitors = currentMonitorsProvider()
        if case let .disconnected(monitorId) = event,
           Monitor.isUsableConfiguration(currentMonitors),
           !currentMonitors.contains(where: { $0.id == monitorId })
        {
            handleMonitorDisconnect(monitorId: monitorId)
        }
        applyMonitorConfigurationChanged(currentMonitors: currentMonitors)
    }

    private func handleMonitorDisconnect(monitorId: Monitor.ID) {
        guard let controller else { return }
        controller.layoutRefreshController.cleanupForMonitorDisconnect(
            displayId: monitorId.displayId,
            migrateAnimations: false
        )

        controller.workspaceManager.withEngineMutationScope {
            controller.niriEngine?.cleanupRemovedMonitor(monitorId)
        }
    }

    @discardableResult
    func refreshForServiceStart(currentMonitors: [Monitor]) -> Bool {
        guard let controller else { return false }
        guard Monitor.isUsableConfiguration(currentMonitors) else { return false }
        guard controller.workspaceManager.monitors != currentMonitors else { return false }
        controller.workspaceManager.applyMonitorConfigurationChange(currentMonitors)
        return true
    }

    func applyMonitorConfigurationChanged(
        currentMonitors: [Monitor],
        performPostUpdateActions: Bool = true
    ) {
        guard let controller else { return }
        guard Monitor.isUsableConfiguration(currentMonitors) else {
            if performPostUpdateActions {
                inventory.schedule(reason: .monitorConfigurationChanged)
            }
            return
        }

        let topologyChanged = controller.workspaceManager.monitors != currentMonitors
        controller.workspaceManager.applyMonitorConfigurationChange(currentMonitors)
        controller.resetMouseWarpTransientState()
        controller.syncMouseWarpPolicy(for: controller.workspaceManager.monitors)
        if topologyChanged {
            controller.publishDisplayChanged()
        }
        guard performPostUpdateActions else { return }

        controller.syncMonitorsToNiriEngine()
        controller.surfaceReconciler.noteWorldChanged()

        let focusedWsId = controller.workspaceManager.selectedManagedToken
            .flatMap { controller.workspaceManager.workspace(for: $0) }
        controller.workspaceManager.garbageCollectUnusedWorkspaces(focusedWorkspaceId: focusedWsId)

        inventory.schedule(reason: .monitorConfigurationChanged)
        controller.reapplyQuakeTerminalGeometryForMonitorChange()
        controller.refreshKeyboardModeIndicator()
    }
}
