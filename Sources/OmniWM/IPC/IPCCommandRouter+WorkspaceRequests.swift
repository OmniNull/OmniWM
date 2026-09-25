// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension IPCCommandRouter {
    func handle(_ request: IPCWorkspaceRequest) -> ExternalCommandResult {
        if let guardResult = IPCCommandValidation.controllerState(controller) {
            return guardResult
        }

        switch request {
        case let .focusName(target):
            return focusWorkspace(target)
        case let .moveToMonitor(target, ipcDirection, force):
            return moveWorkspaceToMonitor(
                target,
                direction: Direction(ipc: ipcDirection),
                force: force
            )
        case let .rename(target, displayName):
            return renameWorkspace(target, displayName: displayName)
        }
    }

    private func focusWorkspace(_ target: WorkspaceTarget) -> ExternalCommandResult {
        let rawWorkspaceID: String
        switch IPCCommandValidation.workspaceTarget(target, controller: controller) {
        case let .success(resolved):
            rawWorkspaceID = resolved
        case let .failure(result):
            return result
        }

        if let currentWorkspace = controller.activeWorkspace(),
           currentWorkspace.name == rawWorkspaceID,
           controller.workspaceNavigationHandler.canSkipSwitch(toVisibleWorkspace: currentWorkspace.id)
        {
            return .noChange
        }
        return controller.windowActionHandler.focusWorkspaceFromBar(named: rawWorkspaceID) ? .executed : .notFound
    }

    private func moveWorkspaceToMonitor(
        _ target: WorkspaceTarget,
        direction: Direction,
        force: Bool
    ) -> ExternalCommandResult {
        let rawWorkspaceID: String
        switch IPCCommandValidation.workspaceTarget(target, controller: controller) {
        case let .success(resolved):
            rawWorkspaceID = resolved
        case let .failure(result):
            return result
        }

        guard let workspaceId = controller.workspaceManager.workspaceId(
            for: rawWorkspaceID,
            createIfMissing: false
        ),
            let outcome = controller.workspaceNavigationHandler.moveWorkspaceToMonitor(
                workspaceId,
                direction: direction,
                force: force
            )
        else {
            return .notFound
        }

        switch outcome.status {
        case .executed:
            return .executed
        case .conflict:
            return .workspaceAssignmentConflict
        case .stateConflict:
            return .workspaceStateConflict
        case .notFound:
            return .notFound
        }
    }

    private func renameWorkspace(_ target: WorkspaceTarget, displayName: String) -> ExternalCommandResult {
        guard !displayName.contains(where: \.isNewline) else { return .invalidArguments }
        let rawWorkspaceID: String
        switch IPCCommandValidation.workspaceTarget(target, controller: controller) {
        case let .success(resolved):
            rawWorkspaceID = resolved
        case let .failure(result):
            return result
        }

        return controller.setWorkspaceDisplayName(displayName, forWorkspaceNamed: rawWorkspaceID)
    }
}
