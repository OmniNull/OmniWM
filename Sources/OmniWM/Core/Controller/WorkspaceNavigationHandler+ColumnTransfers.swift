// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WorkspaceNavigationHandler {
    func moveColumnToAdjacentWorkspace(direction: Direction) {
        guard let controller else { return }
        guard let token = controller.workspaceManager.selectedManagedToken else { return }
        guard let sourceWorkspaceId = controller.workspaceManager.workspace(for: token) else { return }

        saveNiriViewportState(for: sourceWorkspaceId)
        guard case let .changed(mutation) = moveColumnToAdjacentWorkspace(
            containing: WindowHandle(id: token),
            direction: direction
        ) else { return }

        finishWorkspaceMove(mutation)
    }

    func moveColumnToWorkspaceByIndex(index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        moveColumnToWorkspace(rawWorkspaceID: rawWorkspaceID)
    }

    func moveColumnToWorkspace(rawWorkspaceID: String) {
        guard let controller else { return }
        guard let token = controller.workspaceManager.selectedManagedToken else { return }
        guard let sourceWorkspaceId = controller.workspaceManager.workspace(for: token),
              let targetWorkspaceId = controller.workspaceManager.workspaceId(
                  for: rawWorkspaceID,
                  createIfMissing: false
              )
        else { return }

        saveNiriViewportState(for: sourceWorkspaceId)
        guard case let .changed(mutation) = moveColumn(
            containing: WindowHandle(id: token),
            toWorkspaceId: targetWorkspaceId
        ) else { return }

        finishWorkspaceMove(mutation)
    }

    func moveColumn(
        containing handle: WindowHandle,
        toWorkspaceId targetWorkspaceId: WorkspaceDescriptor.ID
    ) -> StructuralMutationOutcome {
        guard let controller,
              let engine = controller.niriEngine,
              !controller.workspaceManager.isWindowSuppressedByMacOS(handle.id),
              let sourceWorkspaceId = controller.workspaceManager.workspace(for: handle.id),
              sourceWorkspaceId != targetWorkspaceId,
              controller.workspaceManager.activeLayoutKind(for: sourceWorkspaceId) == .niri,
              controller.workspaceManager.activeLayoutKind(for: targetWorkspaceId) == .niri,
              let targetMonitor = controller.workspaceManager.monitorForWorkspace(targetWorkspaceId),
              let windowNode = engine.findNode(for: handle, in: sourceWorkspaceId),
              let column = engine.findColumn(containing: windowNode, in: sourceWorkspaceId)
        else {
            return .unchanged
        }

        let movedTokens = column.windowNodes.map(\.token)
        let targetWorkingFrame = controller.niriWorkingFrame(for: targetMonitor)
        let gaps = controller.innerGap(for: targetMonitor)
        let motion = controller.motionPolicy.snapshot()
        let orientation = controller.settings.monitors.effectiveOrientation(for: targetMonitor)
        let transfer = ColumnTransferLayout(
            column: column,
            selectedWindow: windowNode,
            sourceWorkspaceId: sourceWorkspaceId,
            target: NiriInteractionContext(
                workspaceId: targetWorkspaceId,
                motion: motion,
                workingFrame: targetWorkingFrame,
                gaps: gaps,
                orientation: orientation
            ),
            movedTokens: movedTokens
        )
        guard let result = applyColumnTransfer(transfer, engine: engine, controller: controller)
        else { return .unchanged }

        return completeColumnTransfer(
            handle,
            from: sourceWorkspaceId,
            to: targetWorkspaceId,
            sourceFocusNodeId: result.newFocusNodeId
        )
    }

    func moveColumn(
        containing handle: WindowHandle,
        toWorkspaceIndex index: Int
    ) -> StructuralMutationOutcome {
        guard let controller,
              let rawWorkspaceId = WorkspaceIDPolicy.rawID(from: max(0, index) + 1),
              let targetWorkspaceId = controller.workspaceManager.workspaceId(
                  for: rawWorkspaceId,
                  createIfMissing: false
              )
        else {
            return .unchanged
        }
        return moveColumn(containing: handle, toWorkspaceId: targetWorkspaceId)
    }

    func moveColumnToAdjacentWorkspace(
        containing handle: WindowHandle,
        direction: Direction
    ) -> StructuralMutationOutcome {
        guard direction == .up || direction == .down,
              let controller,
              let sourceWorkspaceId = controller.workspaceManager.workspace(for: handle.id),
              controller.workspaceManager.activeLayoutKind(for: sourceWorkspaceId) == .niri,
              let sourceNode = controller.niriEngine?.findNode(for: handle, in: sourceWorkspaceId),
              controller.niriEngine?.findColumn(containing: sourceNode, in: sourceWorkspaceId) != nil,
              let sourceMonitorId = controller.workspaceManager.monitorId(for: sourceWorkspaceId),
              let targetWorkspace = resolveOrCreateAdjacentWorkspace(
                  from: sourceWorkspaceId,
                  direction: direction,
                  on: sourceMonitorId,
                  requiredLayoutKind: .niri
              )
        else {
            return .unchanged
        }
        return moveColumn(containing: handle, toWorkspaceId: targetWorkspace.id)
    }

    private func completeColumnTransfer(
        _ handle: WindowHandle,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        sourceFocusNodeId: NodeId?
    ) -> StructuralMutationOutcome {
        guard let controller else { return .unchanged }
        recordLayoutOperation(.columnMovedToWorkspace(to: targetWorkspaceId), in: sourceWorkspaceId)
        applySessionPatch(workspaceId: targetWorkspaceId, rememberedFocusToken: handle.id)
        controller.recoverSourceFocusAfterMove(
            in: sourceWorkspaceId,
            preferredNodeId: sourceFocusNodeId
        )

        let targetState = controller.workspaceManager.niriViewportState(for: targetWorkspaceId)
        return .changed(
            StructuralMutation(
                sourceWorkspaceId: sourceWorkspaceId,
                destinationWorkspaceId: targetWorkspaceId,
                selectedHandle: handle,
                scrollWorkspaceId: targetState.hasPendingOffsetAnimation ? targetWorkspaceId : nil
            )
        )
    }

    private struct ColumnTransferLayout {
        let column: NiriContainer
        let selectedWindow: NiriWindow
        let sourceWorkspaceId: WorkspaceDescriptor.ID
        let target: NiriInteractionContext
        let movedTokens: [WindowToken]
    }

    private func applyColumnTransfer(
        _ transfer: ColumnTransferLayout,
        engine: NiriLayoutEngine,
        controller: WMController
    ) -> NiriLayoutEngine.WorkspaceMoveResult? {
        return controller.workspaceManager.withBatchedWorkspaceMove(
            sourceWorkspaceId: transfer.sourceWorkspaceId,
            targetWorkspaceId: transfer.target.workspaceId,
            { sourceState, targetState in
                guard let moveResult = engine.moveColumnToWorkspace(
                    transfer.column,
                    from: transfer.sourceWorkspaceId,
                    to: NiriWorkspaceDestination(
                        workspaceId: transfer.target.workspaceId,
                        orientation: transfer.target.orientation
                    ),
                    sourceState: &sourceState,
                    targetState: &targetState
                ) else { return nil }
                engine.activateWindow(transfer.selectedWindow.id, in: transfer.target.workspaceId)
                targetState.selectedNodeId = transfer.selectedWindow.id
                engine.ensureSelectionVisible(
                    node: transfer.selectedWindow,
                    context: transfer.target,
                    state: &targetState
                )
                return (moveResult, transfer.movedTokens)
            }
        )
    }
}
