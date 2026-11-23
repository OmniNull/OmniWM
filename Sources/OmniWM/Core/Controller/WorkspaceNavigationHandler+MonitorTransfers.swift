// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WorkspaceNavigationHandler {
    @discardableResult
    func moveWindowToMonitor(direction: Direction) -> ExternalCommandResult {
        moveFocusedWindowToMonitor(direction: direction, focusPolicy: .configured)
    }

    func moveWindowAcrossMonitorAtEdge(direction: Direction) {
        _ = moveFocusedWindowToMonitor(direction: direction, focusPolicy: .alwaysFollow)
    }

    private func moveFocusedWindowToMonitor(
        direction: Direction,
        focusPolicy: WorkspaceMoveFocusPolicy
    ) -> ExternalCommandResult {
        guard let controller,
              let token = controller.workspaceManager.selectedManagedToken,
              let source = controller.workspaceManager.workspace(for: token),
              let monitor = controller.workspaceManager.monitorId(for: source),
              let adjacent = controller.workspaceManager.adjacentMonitor(from: monitor, direction: direction)
        else { return .notFound }

        saveNiriViewportState(for: source)
        guard case let .changed(mutation) = moveWindow(
            handle: WindowHandle(id: token), from: source, to: adjacent, direction: direction, controller: controller
        ) else { return .noChange }
        finishWorkspaceMove(mutation, focusPolicy: focusPolicy)
        return .executed
    }

    func moveWindowToMonitor(
        handle: WindowHandle,
        direction: Direction
    ) -> StructuralMutationOutcome {
        guard let controller,
              let source = controller.workspaceManager.workspace(for: handle.id),
              let monitor = controller.workspaceManager.monitorId(for: source),
              let adjacent = controller.workspaceManager.adjacentMonitor(from: monitor, direction: direction)
        else { return .unchanged }
        return moveWindow(handle: handle, from: source, to: adjacent, direction: direction, controller: controller)
    }

    private func moveWindow(
        handle: WindowHandle,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetMonitor: Monitor,
        direction: Direction,
        controller: WMController
    ) -> StructuralMutationOutcome {
        guard controller.workspaceManager.entry(for: handle.id)?.target.hostedMetadata?.role.parent == nil,
              let targetWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: targetMonitor.id),
              targetWorkspace.id != sourceWorkspaceId
        else { return .unchanged }

        let targetIsNiri = controller.workspaceManager.activeLayoutKind(for: targetWorkspace.id) == .niri
        let anchorToken: WindowToken? = targetIsNiri ? Self.spatialNeighborToken(
            from: controller.preferredKeyboardFocusFrame(for: handle.id),
            candidates: controller.workspaceManager.tiledEntries(in: targetWorkspace.id)
                .filter { !controller.isManagedWindowSuppressedByMacOS($0.token) }
                .compactMap { entry in
                    controller.preferredKeyboardFocusFrame(for: entry.token).map { (token: entry.token, frame: $0) }
                },
            direction: direction,
            targetFrame: controller.insetWorkingFrame(for: targetMonitor)
        ) : nil

        let outcome = moveWindow(handle: handle, toWorkspaceId: targetWorkspace.id)
        guard case let .changed(mutation) = outcome else { return outcome }

        if targetIsNiri,
           controller.niriEngine?.findNode(for: handle, in: targetWorkspace.id) != nil
        {
            controller.niriLayoutHandler.consumeTransferredWindow(
                handle.id,
                in: targetWorkspace.id,
                enteringFrom: direction,
                anchorToken: anchorToken
            )
        }

        return .changed(
            StructuralMutation(
                sourceWorkspaceId: mutation.sourceWorkspaceId,
                destinationWorkspaceId: mutation.destinationWorkspaceId,
                selectedHandle: mutation.selectedHandle,
                scrollWorkspaceId: nil
            )
        )
    }

    @discardableResult
    func swapCurrentWorkspaceWithMonitor(direction: Direction) -> ExternalCommandResult {
        guard let controller else { return .notFound }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return .notFound }

        guard let targetMonitor = controller.workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else { return .notFound }

        guard let currentWsId = controller.activeWorkspace()?.id,
              let targetWsId = controller.workspaceManager.activeWorkspace(on: targetMonitor.id)?.id
        else { return .noChange }

        saveNiriViewportState(for: currentWsId)
        restoreRememberedSelection(in: targetWsId)

        guard controller.workspaceManager.swapWorkspaces(
            currentWsId, on: currentMonitorId,
            with: targetWsId, on: targetMonitor.id
        ) else { return .noChange }

        controller.syncMonitorsToNiriEngine()

        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: targetWsId)

        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: [currentWsId, targetWsId],
            reason: .workspaceTransition
        ) { [weak controller] in
            if let focusToken {
                controller?.focusWindow(focusToken)
            }
        }
        return .executed
    }

    func moveWorkspaceToMonitor(
        _ workspaceId: WorkspaceDescriptor.ID,
        direction: Direction,
        force: Bool
    ) -> WorkspaceMonitorMoveOutcome? {
        guard let controller,
              let sourceMonitor = controller.workspaceManager.monitorForWorkspace(workspaceId),
              let targetMonitor = controller.workspaceManager.adjacentMonitor(
                  from: sourceMonitor.id,
                  direction: direction
              )
        else {
            return nil
        }
        return moveWorkspaceToMonitor(workspaceId, to: targetMonitor.id, force: force)
    }

    func moveWorkspaceToMonitor(
        _ workspaceId: WorkspaceDescriptor.ID,
        to targetMonitorId: Monitor.ID,
        force: Bool
    ) -> WorkspaceMonitorMoveOutcome? {
        guard let controller else { return nil }
        let outcome = controller.workspaceManager.moveWorkspaceToMonitor(
            workspaceId,
            to: targetMonitorId,
            force: force
        )
        controller.layoutRefreshController.commitWorkspaceMonitorTransition(outcome)
        return outcome
    }

    func moveWindowToWorkspaceOnMonitor(
        handle: WindowHandle,
        workspaceIndex: Int,
        monitorDirection: Direction
    ) -> StructuralMutationOutcome {
        guard let rawWorkspaceId = WorkspaceIDPolicy.rawID(from: max(0, workspaceIndex) + 1) else {
            return .unchanged
        }
        return moveWindowToWorkspaceOnMonitor(
            handle: handle,
            rawWorkspaceId: rawWorkspaceId,
            monitorDirection: monitorDirection
        )
    }

    func moveWindowToWorkspaceOnMonitor(
        handle: WindowHandle,
        rawWorkspaceId: String,
        monitorDirection: Direction
    ) -> StructuralMutationOutcome {
        guard let controller,
              let sourceWorkspaceId = controller.workspaceManager.workspace(for: handle.id),
              let sourceMonitorId = controller.workspaceManager.monitorId(for: sourceWorkspaceId),
              let targetMonitor = controller.workspaceManager.adjacentMonitor(
                  from: sourceMonitorId,
                  direction: monitorDirection
              ),
              let targetWorkspaceId = controller.workspaceManager.workspaceId(
                  for: rawWorkspaceId,
                  createIfMissing: false
              ),
              controller.workspaceManager.monitorId(for: targetWorkspaceId) == targetMonitor.id
        else {
            return .unchanged
        }
        return moveWindow(handle: handle, toWorkspaceId: targetWorkspaceId)
    }

    @discardableResult
    func moveFocusedWindow(toWorkspaceIndex index: Int, onMonitor direction: Direction) -> ExternalCommandResult {
        guard index >= 0, index < Int.max else { return .invalidArguments }
        let rawWorkspaceID = String(index + 1)
        guard let controller, let token = controller.workspaceManager.selectedManagedToken else { return .notFound }
        if let source = controller.workspaceManager.workspace(for: token),
           controller.workspaceManager.descriptor(for: source)?.name == rawWorkspaceID
        {
            return .noChange
        }
        guard case let .changed(mutation) = moveWindowToWorkspaceOnMonitor(
            handle: WindowHandle(id: token),
            rawWorkspaceId: rawWorkspaceID,
            monitorDirection: direction
        ) else { return .notFound }

        finishWorkspaceMove(mutation)
        return .executed
    }
}
