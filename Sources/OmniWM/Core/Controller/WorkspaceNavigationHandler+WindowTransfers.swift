// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WorkspaceNavigationHandler {
    struct WindowTransferResult {
        let succeeded: Bool
        let newSourceFocusToken: WindowToken?
    }

    @discardableResult
    func moveFocusedWindow(toWorkspaceSlot slot: Int) -> Bool {
        guard let controller,
              let token = controller.workspaceManager.selectedManagedToken,
              let targetWorkspace = workspaceSlot(slot),
              controller.workspaceManager.workspace(for: token) != targetWorkspace.id
        else { return false }
        if case .changed = commitWindowMove(handle: WindowHandle(id: token), toWorkspaceId: targetWorkspace.id) {
            return true
        }
        return false
    }

    private func transferWindowFromSourceEngine(
        token: WindowToken,
        from sourceWsId: WorkspaceDescriptor.ID?,
        to targetWsId: WorkspaceDescriptor.ID
    ) -> WindowTransferResult {
        guard let controller else { return WindowTransferResult(succeeded: false, newSourceFocusToken: nil) }
        let transfer = WindowEngineTransfer(
            token: token,
            sourceWorkspaceId: sourceWsId,
            targetWorkspaceId: targetWsId,
            controller: controller
        )
        var progress = WindowEngineTransferProgress()
        if controller.workspaceManager.windowMode(for: token) == .floating {
            controller.reassignManagedWindow(token, to: targetWsId)
            if let sourceWsId {
                recordLayoutOperation(.windowMovedToWorkspace(token: token, to: targetWsId), in: sourceWsId)
            }
            return WindowTransferResult(succeeded: true, newSourceFocusToken: nil)
        }
        transferNiriWindow(transfer, controller: controller, progress: &progress)
        detachTransferredWindow(transfer, controller: controller, progress: &progress)
        let succeeded = progress.movedWithNiri || sourceWsId == nil || transfer.sourceIsDwindle || transfer
            .targetIsDwindle
        if succeeded {
            if !progress.movedWithNiri {
                controller.dwindleLayoutHandler.markIncomingWindowForStacking(token, in: targetWsId)
                controller.reassignManagedWindow(token, to: targetWsId)
            }
            if let sourceWsId {
                recordLayoutOperation(.windowMovedToWorkspace(token: token, to: targetWsId), in: sourceWsId)
            }
        }

        return WindowTransferResult(succeeded: succeeded, newSourceFocusToken: progress.newSourceFocusToken)
    }

    func moveWindowToAdjacentWorkspace(direction: Direction) {
        guard let controller else { return }
        guard let token = controller.workspaceManager.selectedManagedToken else { return }
        guard let sourceWorkspaceId = controller.workspaceManager.workspace(for: token) else { return }

        saveNiriViewportState(for: sourceWorkspaceId)
        guard case let .changed(mutation) = moveWindowToAdjacentWorkspace(
            handle: WindowHandle(id: token),
            direction: direction
        ) else { return }

        finishWorkspaceMove(mutation)
    }

    func moveFocusedWindow(toWorkspaceIndex index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        moveFocusedWindow(toRawWorkspaceID: rawWorkspaceID)
    }

    func moveFocusedWindow(toRawWorkspaceID rawWorkspaceID: String) {
        guard let controller,
              let token = controller.workspaceManager.selectedManagedToken,
              let targetWorkspaceId = controller.workspaceManager.workspaceId(
                  for: rawWorkspaceID,
                  createIfMissing: false
              )
        else { return }
        commitWindowMove(handle: WindowHandle(id: token), toWorkspaceId: targetWorkspaceId)
    }

    @discardableResult
    func commitWindowMove(
        handle: WindowHandle,
        toWorkspaceId targetWorkspaceId: WorkspaceDescriptor.ID
    ) -> StructuralMutationOutcome {
        let outcome = moveWindow(handle: handle, toWorkspaceId: targetWorkspaceId)
        if case let .changed(mutation) = outcome, let controller {
            let movesSelection = controller.workspaceManager.selectedManagedToken == handle.id
            finishWorkspaceMove(mutation, focusPolicy: movesSelection ? .configured : .retainCurrent)
        }
        return outcome
    }

    @discardableResult
    func moveWindow(
        handle: WindowHandle,
        toWorkspaceId targetWsId: WorkspaceDescriptor.ID
    ) -> StructuralMutationOutcome {
        guard let controller,
              controller.workspaceManager.descriptor(for: targetWsId) != nil,
              controller.workspaceManager.monitorForWorkspace(targetWsId) != nil,
              !controller.workspaceManager.isWindowSuppressedByMacOS(handle.id)
        else {
            return .unchanged
        }
        let token = handle.id

        guard let currentWorkspaceId = controller.workspaceManager.workspace(for: token),
              currentWorkspaceId != targetWsId
        else {
            return .unchanged
        }
        let transferResult = transferWindowFromSourceEngine(
            token: token,
            from: currentWorkspaceId,
            to: targetWsId
        )
        guard transferResult.succeeded else { return .unchanged }

        let targetViewportState = transferredWindowNiriViewportState(
            token: token,
            workspaceId: targetWsId
        )
        applySessionPatch(
            workspaceId: targetWsId,
            viewportState: targetViewportState,
            rememberedFocusToken: token
        )

        recoverSourceFocus(after: transferResult, from: currentWorkspaceId)

        return .changed(
            StructuralMutation(
                sourceWorkspaceId: currentWorkspaceId,
                destinationWorkspaceId: targetWsId,
                selectedHandle: handle,
                movedTokens: [token],
                scrollWorkspaceId: targetViewportState?.hasPendingOffsetAnimation == true ? targetWsId : nil
            )
        )
    }

    func moveWindow(
        handle: WindowHandle,
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
        return moveWindow(handle: handle, toWorkspaceId: targetWorkspaceId)
    }

    func moveWindowToAdjacentWorkspace(
        handle: WindowHandle,
        direction: Direction
    ) -> StructuralMutationOutcome {
        guard direction == .up || direction == .down,
              let controller,
              let sourceWorkspaceId = controller.workspaceManager.workspace(for: handle.id),
              canTransferWindow(handle, from: sourceWorkspaceId),
              let sourceMonitorId = controller.workspaceManager.monitorId(for: sourceWorkspaceId),
              let targetWorkspace = resolveOrCreateAdjacentWorkspace(
                  from: sourceWorkspaceId,
                  direction: direction,
                  on: sourceMonitorId
              )
        else {
            return .unchanged
        }
        return moveWindow(handle: handle, toWorkspaceId: targetWorkspace.id)
    }

    private func canTransferWindow(
        _ handle: WindowHandle,
        from workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller else { return false }
        if controller.workspaceManager.windowMode(for: handle.id) == .floating {
            return true
        }
        switch controller.workspaceManager.activeLayoutKind(for: workspaceId) {
        case .niri:
            return controller.niriEngine?.findNode(for: handle, in: workspaceId) != nil
        case .dwindle:
            return controller.dwindleEngine?.findNode(for: handle.id, in: workspaceId) != nil
        }
    }

    private func transferNiriWindow(
        _ transfer: WindowEngineTransfer,
        controller: WMController,
        progress: inout WindowEngineTransferProgress
    ) {
        let token = transfer.token
        let sourceWsId = transfer.sourceWorkspaceId
        let targetWsId = transfer.targetWorkspaceId
        let sourceIsDwindle = transfer.sourceIsDwindle
        let targetIsDwindle = transfer.targetIsDwindle
        if !sourceIsDwindle,
           !targetIsDwindle,
           let sourceWsId,
           let engine = controller.niriEngine,
           let windowNode = engine.findNode(for: token, in: sourceWsId)
        {
            let result = controller.workspaceManager.withBatchedWorkspaceMove(
                sourceWorkspaceId: sourceWsId,
                targetWorkspaceId: targetWsId
            ) { sourceState, targetState in
                guard let moveResult = engine.moveWindowToWorkspace(
                    windowNode,
                    from: sourceWsId,
                    to: targetWsId,
                    sourceState: &sourceState,
                    targetState: &targetState
                ) else { return nil }
                return (moveResult, [token])
            }
            if let result {
                if let newFocusId = result.newFocusNodeId,
                   let newFocusNode = engine.findNode(by: newFocusId, in: sourceWsId) as? NiriWindow
                {
                    progress.newSourceFocusToken = newFocusNode.token
                }
                progress.movedWithNiri = true
            }
        }
    }

    private func detachTransferredWindow(
        _ transfer: WindowEngineTransfer,
        controller: WMController,
        progress: inout WindowEngineTransferProgress
    ) {
        let token = transfer.token
        let sourceWsId = transfer.sourceWorkspaceId
        let sourceIsDwindle = transfer.sourceIsDwindle
        let targetIsDwindle = transfer.targetIsDwindle
        if !progress.movedWithNiri,
           !sourceIsDwindle,
           let sourceWsId,
           let engine = controller.niriEngine
        {
            controller.workspaceManager.withBatchedNiriSourceMutation(workspaceId: sourceWsId) { sourceState in
                if let currentNode = engine.findNode(for: token, in: sourceWsId),
                   sourceState.selectedNodeId == currentNode.id
                {
                    sourceState.selectedNodeId = engine.fallbackSelectionOnRemoval(
                        removing: currentNode.id,
                        in: sourceWsId
                    )
                }

                if targetIsDwindle, engine.findNode(for: token, in: sourceWsId) != nil {
                    controller.workspaceManager.captureDetachedNiriPlacement(for: token, in: sourceWsId)
                    engine.removeWindow(token: token, in: sourceWsId)
                }

                if let selectedId = sourceState.selectedNodeId,
                   engine.findNode(by: selectedId, in: sourceWsId) == nil
                {
                    sourceState.selectedNodeId = engine.validateSelection(selectedId, in: sourceWsId)
                }

                if let selectedId = sourceState.selectedNodeId,
                   let selectedNode = engine.findNode(by: selectedId, in: sourceWsId) as? NiriWindow
                {
                    progress.newSourceFocusToken = selectedNode.token
                }
            }
        } else if sourceIsDwindle,
                  let sourceWsId,
                  let dwindleEngine = controller.dwindleEngine
        {
            progress.newSourceFocusToken = controller.workspaceManager.withEngineMutationScope(in: sourceWsId) {
                dwindleEngine.removeWindow(token: token, from: sourceWsId)
                return dwindleEngine.selectedNode(in: sourceWsId)?.windowToken
            }
        }
    }
}
