// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WorkspaceNavigationHandler {
    @discardableResult
    func switchWorkspace(index: Int, autoBackAndForth: Bool = false, anywhere: Bool = false) -> ExternalCommandResult {
        guard index >= 0, index < Int.max else { return .invalidArguments }
        return selectWorkspace(rawID: String(index + 1), anywhere: anywhere, autoBackAndForth: autoBackAndForth)
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
        selectWorkspace(rawID: rawWorkspaceID, affectedWorkspaces: affectedWorkspaces) == .executed
    }

    private func selectWorkspace(
        rawID: String,
        anywhere: Bool = false,
        autoBackAndForth: Bool = false,
        affectedWorkspaces: Set<WorkspaceDescriptor.ID> = []
    ) -> ExternalCommandResult {
        guard let controller,
              let targetId = controller.workspaceManager.workspaceId(named: rawID)
        else { return .notFound }
        let current = controller.activeWorkspace()
        if let current, current.id == targetId, canSkipSwitch(toVisibleWorkspace: current.id) {
            guard autoBackAndForth else { return .noChange }
            workspaceBackAndForth()
            return .executed
        }
        guard let targetMonitor = controller.workspaceManager.monitorForWorkspace(targetId) else { return .notFound }
        if anywhere {
            return focusWorkspaceAnywhere(targetId, on: targetMonitor, from: current, controller: controller)
        }
        if controller.settings.slideWorkspaceSwitchesUntracked, affectedWorkspaces.isEmpty,
           let monitorId = interactionMonitorId(for: controller),
           let current,
           controller.workspaceManager.monitor(for: current.id)?.id == monitorId,
           targetMonitor.id == monitorId,
           controller.layoutRefreshController.workspaceSwipe.animateSwitch(to: targetId, on: monitorId, isNext: nil)
        {
            return .executed
        }
        if let current { saveNiriViewportState(for: current.id) }
        guard let result = controller.workspaceManager.focusWorkspace(named: rawID) else { return .notFound }
        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: result.workspace.id, monitor: result.monitor, startScrollAnimation: false,
            affectedWorkspaces: affectedWorkspaces
        )
        return .executed
    }

    struct SwitchOrigin {
        let id: WorkspaceDescriptor.ID?
    }

    @discardableResult
    func switchWorkspaceRelative(
        isNext: Bool,
        wrapAround: Bool = true,
        monitorId explicitMonitorId: Monitor.ID? = nil,
        interactionOrigin: @autoclosure () -> SwitchOrigin? = nil
    ) -> SwitchOrigin? {
        guard let controller else { return nil }
        guard let currentMonitorId = explicitMonitorId ?? interactionMonitorId(for: controller)
        else { return nil }
        let slides = controller.settings.slideWorkspaceSwitchesUntracked
        let pendingId = slides
            ? controller.layoutRefreshController.workspaceSwipe.pendingSwitchTarget(on: currentMonitorId)
            : nil
        let pendingWorkspace = pendingId.flatMap { controller.workspaceManager.descriptor(for: $0) }
        let resolvedWorkspace = pendingWorkspace ?? (explicitMonitorId == nil
            ? controller.activeWorkspace()
            : controller.workspaceManager.activeWorkspaceOrFirst(on: currentMonitorId))
        guard let currentWorkspace = resolvedWorkspace else { return nil }
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

        guard let targetWorkspace else { return nil }
        let origin = pendingWorkspace == nil && explicitMonitorId == nil
            ? SwitchOrigin(id: currentWorkspace.id)
            : interactionOrigin()
        activateWorkspaceInOrder(
            targetWorkspace, from: currentWorkspace.id, on: currentMonitorId, isNext: isNext, animated: slides
        )
        return origin
    }

    func switchWorkspaceBySwipe(isNext: Bool, monitorId: Monitor.ID) {
        guard let controller,
              let currentWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitorId),
              let targetWorkspace = swipeTargetWorkspace(
                  isNext: isNext, from: currentWorkspace.id, on: monitorId, createIfNeeded: true
              )
        else { return }
        controller.layoutRefreshController.workspaceSwipe.noteSwitchWithoutPresentation(on: monitorId)
        activateWorkspaceInOrder(targetWorkspace, from: currentWorkspace.id, on: monitorId)
    }

    func swipeTargetWorkspace(
        isNext: Bool,
        from workspaceId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID,
        createIfNeeded: Bool
    ) -> WorkspaceDescriptor? {
        guard let controller else { return nil }
        let manager = controller.workspaceManager
        let edgeBehavior = controller.settings.gestures.workspaceSwipeEdgeBehavior
        let skipEmpty = skipsEmptyWorkspaces(on: monitorId)
        let wrapAround = edgeBehavior == .cycle
        let adjacent = isNext
            ? manager.nextWorkspaceInOrder(
                on: monitorId,
                from: workspaceId,
                wrapAround: wrapAround,
                skipEmpty: skipEmpty
            )
            : manager.previousWorkspaceInOrder(
                on: monitorId, from: workspaceId, wrapAround: wrapAround, skipEmpty: skipEmpty
            )
        guard adjacent == nil, edgeBehavior == .onePast, isNext, manager.isOccupied(workspaceId) else {
            return adjacent
        }
        let ordered = manager.workspaces(on: monitorId)
        if let index = ordered.firstIndex(where: { $0.id == workspaceId }),
           let empty = ordered[(index + 1)...].first(where: { !manager.isOccupied($0.id) })
        {
            return empty
        }
        return createIfNeeded ? createOverviewWorkspace(on: monitorId) : nil
    }

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
        switchWorkspaceSlotResult(slot, autoBackAndForth: false) == .executed
    }

    func switchWorkspaceSlotResult(_ slot: Int, autoBackAndForth: Bool) -> ExternalCommandResult {
        guard slot >= 1 else { return .invalidArguments }
        guard let controller,
              let monitorId = interactionMonitorId(for: controller),
              let targetWorkspace = workspaceSlot(slot),
              let currentWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        else { return .notFound }
        if currentWorkspace.id == targetWorkspace.id, canSkipSwitch(toVisibleWorkspace: targetWorkspace.id) {
            guard autoBackAndForth else { return .noChange }
            workspaceBackAndForth()
            return .executed
        }
        return activateWorkspaceInOrder(
            targetWorkspace, from: currentWorkspace.id, on: monitorId,
            animated: controller.settings.slideWorkspaceSwitchesUntracked
        ) ? .executed : .notFound
    }

    @discardableResult
    private func activateWorkspaceInOrder(
        _ targetWorkspace: WorkspaceDescriptor,
        from currentWorkspaceId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID,
        isNext: Bool? = nil,
        animated: Bool = false
    ) -> Bool {
        guard let controller else { return false }
        if animated, controller.layoutRefreshController.workspaceSwipe.animateSwitch(
            to: targetWorkspace.id, on: monitorId, isNext: isNext
        ) {
            return true
        }
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

    private func focusWorkspaceAnywhere(
        _ targetWsId: WorkspaceDescriptor.ID,
        on targetMonitor: Monitor,
        from currentWorkspace: WorkspaceDescriptor?,
        controller: WMController
    ) -> ExternalCommandResult {
        if let currentWorkspace {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        let currentMonitorId = interactionMonitorId(for: controller)

        if let currentMonitorId, currentMonitorId != targetMonitor.id {
            if let currentTargetWs = controller.workspaceManager.activeWorkspace(on: targetMonitor.id) {
                saveNiriViewportState(for: currentTargetWs.id)
            }
        }

        guard controller.workspaceManager.setActiveWorkspace(targetWsId, on: targetMonitor.id) else { return .notFound }

        controller.syncMonitorsToNiriEngine()

        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: targetWsId,
            monitor: targetMonitor,
            startScrollAnimation: false
        )
        return .executed
    }

    @discardableResult
    func workspaceBackAndForth() -> SwitchOrigin? {
        guard let controller else { return nil }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return nil }

        guard let prevWorkspace = controller.workspaceManager.previousWorkspace(on: currentMonitorId) else {
            return nil
        }

        let currentWorkspace = controller.activeWorkspace()
        let origin = SwitchOrigin(id: currentWorkspace?.id)
        if controller.settings.slideWorkspaceSwitchesUntracked, let currentWorkspace,
           controller.workspaceManager.monitor(for: currentWorkspace.id)?.id == currentMonitorId,
           controller.workspaceManager.monitor(for: prevWorkspace.id)?.id == currentMonitorId
        {
            activateWorkspaceInOrder(prevWorkspace, from: currentWorkspace.id, on: currentMonitorId, animated: true)
            return origin
        }
        if let currentWorkspace {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        guard controller.workspaceManager.setActiveWorkspace(prevWorkspace.id, on: currentMonitorId) else {
            return origin
        }

        let monitor = controller.workspaceManager.monitor(for: prevWorkspace.id)
            ?? controller.workspaceManager.monitor(byId: currentMonitorId)
        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: prevWorkspace.id,
            monitor: monitor,
            startScrollAnimation: false
        )
        return origin
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
