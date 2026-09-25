// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WorkspaceNavigationHandler {
    func switchWorkspace(index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        switchWorkspace(rawWorkspaceID: rawWorkspaceID)
    }

    func canSkipSwitch(toVisibleWorkspace workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller else { return true }
        let nativeFocusWorkspaceId = controller.workspaceManager.nativeManagedFocusToken
            .flatMap { controller.workspaceManager.workspace(for: $0) }
        return nativeFocusWorkspaceId == nil || nativeFocusWorkspaceId == workspaceId
    }

    @discardableResult
    func switchWorkspace(
        rawWorkspaceID: String,
        affectedWorkspaces: Set<WorkspaceDescriptor.ID> = []
    ) -> Bool {
        guard let controller else { return false }
        let currentWorkspace = controller.activeWorkspace()
        if let currentWorkspace,
           currentWorkspace.name == rawWorkspaceID,
           canSkipSwitch(toVisibleWorkspace: currentWorkspace.id)
        {
            return false
        }

        if let currentWorkspace {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        guard let targetWorkspaceId = controller.workspaceManager.workspaceId(
            for: rawWorkspaceID,
            createIfMissing: false
        ),
            controller.workspaceManager.monitorForWorkspace(targetWorkspaceId) != nil
        else {
            return false
        }

        guard let result = controller.workspaceManager.focusWorkspace(named: rawWorkspaceID) else { return false }

        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: result.workspace.id,
            monitor: result.monitor,
            startScrollAnimation: false,
            affectedWorkspaces: affectedWorkspaces
        )
        return true
    }

    func switchWorkspaceRelative(
        isNext: Bool,
        wrapAround: Bool = true,
        monitorId explicitMonitorId: Monitor.ID? = nil
    ) {
        guard let controller else { return }
        guard let currentMonitorId = explicitMonitorId ?? interactionMonitorId(for: controller)
        else { return }
        let resolvedWorkspace = explicitMonitorId == nil
            ? controller.activeWorkspace()
            : controller.workspaceManager.activeWorkspaceOrFirst(on: currentMonitorId)
        guard let currentWorkspace = resolvedWorkspace else { return }
        let skipEmpty = skipsEmptyWorkspaces(on: currentMonitorId)

        let targetWorkspace: WorkspaceDescriptor? = if isNext {
            controller.workspaceManager.nextWorkspaceInOrder(
                on: currentMonitorId,
                from: currentWorkspace.id,
                wrapAround: wrapAround,
                skipEmpty: skipEmpty
            )
        } else {
            controller.workspaceManager.previousWorkspaceInOrder(
                on: currentMonitorId,
                from: currentWorkspace.id,
                wrapAround: wrapAround,
                skipEmpty: skipEmpty
            )
        }

        guard let targetWorkspace else { return }
        activateWorkspaceInOrder(targetWorkspace, from: currentWorkspace.id, on: currentMonitorId)
    }

    /// Relative workspace navigation skips empty workspaces when the monitor's bar hides them.
    func skipsEmptyWorkspaces(on monitorId: Monitor.ID) -> Bool {
        guard let controller, let monitor = controller.workspaceManager.monitor(byId: monitorId) else {
            return false
        }
        return controller.settings.workspaceBar.resolved(for: monitor).hideEmptyWorkspaces
    }

    func workspaceSlot(_ slot: Int) -> WorkspaceDescriptor? {
        guard let controller, slot >= 1, let monitorId = interactionMonitorId(for: controller) else { return nil }
        let ordered = controller.workspaceManager.workspaces(on: monitorId)
        return ordered.indices.contains(slot - 1) ? ordered[slot - 1] : nil
    }

    @discardableResult
    func switchWorkspaceSlot(_ slot: Int) -> Bool {
        guard let controller,
              let monitorId = interactionMonitorId(for: controller),
              let targetWorkspace = workspaceSlot(slot),
              let currentWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        else { return false }
        if currentWorkspace.id == targetWorkspace.id, canSkipSwitch(toVisibleWorkspace: targetWorkspace.id) {
            return false
        }
        return activateWorkspaceInOrder(targetWorkspace, from: currentWorkspace.id, on: monitorId)
    }

    @discardableResult
    private func activateWorkspaceInOrder(
        _ targetWorkspace: WorkspaceDescriptor,
        from currentWorkspaceId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID
    ) -> Bool {
        guard let controller else { return false }
        saveNiriViewportState(for: currentWorkspaceId)
        guard controller.workspaceManager.setActiveWorkspace(targetWorkspace.id, on: monitorId) else {
            return false
        }

        let monitor = controller.workspaceManager.monitor(for: targetWorkspace.id)
            ?? controller.workspaceManager.monitor(byId: monitorId)
        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: targetWorkspace.id,
            monitor: monitor,
            startScrollAnimation: false
        )
        return true
    }

    func saveNiriViewportState(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        guard controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri else { return }
        guard let engine = controller.niriEngine else { return }

        if let focusedToken = controller.workspaceManager.selectedManagedToken,
           controller.workspaceManager.workspace(for: focusedToken) == workspaceId,
           let focusedNode = engine.findNode(for: focusedToken, in: workspaceId)
        {
            commitWorkspaceSelection(
                nodeId: focusedNode.id,
                focusedToken: focusedToken,
                in: workspaceId
            )
        }
    }

    @discardableResult
    func focusWorkspaceAnywhere(rawWorkspaceID: String) -> Bool {
        guard let controller else { return false }
        let currentWorkspace = controller.activeWorkspace()

        guard let targetWsId = controller.workspaceManager.workspaceId(named: rawWorkspaceID) else { return false }
        guard let targetMonitor = controller.workspaceManager.monitorForWorkspace(targetWsId) else { return false }

        if let currentWorkspace {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        let currentMonitorId = interactionMonitorId(for: controller)

        if let currentMonitorId, currentMonitorId != targetMonitor.id {
            if let currentTargetWs = controller.workspaceManager.activeWorkspace(on: targetMonitor.id) {
                saveNiriViewportState(for: currentTargetWs.id)
            }
        }

        guard controller.workspaceManager.setActiveWorkspace(targetWsId, on: targetMonitor.id) else { return false }

        controller.syncMonitorsToNiriEngine()

        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: targetWsId,
            monitor: targetMonitor,
            startScrollAnimation: false
        )
        return true
    }

    func workspaceBackAndForth() {
        guard let controller else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }

        guard let prevWorkspace = controller.workspaceManager.previousWorkspace(on: currentMonitorId) else {
            return
        }

        let currentWorkspace = controller.activeWorkspace()
        if let currentWorkspace {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        guard controller.workspaceManager.setActiveWorkspace(prevWorkspace.id, on: currentMonitorId) else {
            return
        }

        let monitor = controller.workspaceManager.monitor(for: prevWorkspace.id)
            ?? controller.workspaceManager.monitor(byId: currentMonitorId)
        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: prevWorkspace.id,
            monitor: monitor,
            startScrollAnimation: false
        )
    }

    func resolveOrCreateAdjacentWorkspace(
        from workspaceId: WorkspaceDescriptor.ID,
        direction: Direction,
        on monitorId: Monitor.ID,
        requiredLayoutKind: ActiveLayoutKind? = nil
    ) -> WorkspaceDescriptor? {
        guard let controller else { return nil }
        let wm = controller.workspaceManager

        let existing: WorkspaceDescriptor? = if direction == .down {
            wm.nextWorkspaceInOrder(on: monitorId, from: workspaceId, wrapAround: false)
        } else {
            wm.previousWorkspaceInOrder(on: monitorId, from: workspaceId, wrapAround: false)
        }
        if let existing { return existing }

        guard let currentName = wm.descriptor(for: workspaceId)?.name,
              let currentNumber = Int(currentName)
        else { return nil }

        var candidateNumber = direction == .down ? currentNumber + 1 : currentNumber - 1
        while candidateNumber > 0 {
            let candidateName = String(candidateNumber)
            if wm.workspaceId(named: candidateName) == nil {
                let candidateLayoutKind: ActiveLayoutKind = controller.settings.workspaces
                    .layoutType(for: candidateName)
                    == .dwindle ? .dwindle : .niri
                guard requiredLayoutKind == nil || candidateLayoutKind == requiredLayoutKind else { return nil }
                guard let workspace = wm.createDynamicWorkspace(named: candidateName, on: monitorId) else {
                    return nil
                }
                controller.syncMonitorsToNiriEngine()
                return workspace
            }
            let delta = direction == .down ? 1 : -1
            let next = candidateNumber.addingReportingOverflow(delta)
            guard !next.overflow else { return nil }
            candidateNumber = next.partialValue
        }
        return nil
    }
}
