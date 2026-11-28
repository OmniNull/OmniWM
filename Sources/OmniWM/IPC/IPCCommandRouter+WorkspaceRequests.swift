// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMAutomation
import OmniWMIPC

extension IPCCommandRouter {
    func handle(_ request: IPCWorkspaceRequest) -> ExternalCommandResult {
        if let guardResult = controller.automationRefusal {
            return guardResult
        }

        let (target, action): (WorkspaceTarget, WorkspaceTargetAction) = switch request {
        case let .focusName(target):
            (target, .focus)
        case let .moveToMonitor(target, ipcDirection, force):
            (target, .moveToMonitor(Direction(ipc: ipcDirection), force: force))
        case let .rename(target, displayName):
            (target, .rename(displayName))
        }
        guard action.hasValidArguments else { return .invalidArguments }

        switch controller.resolveWorkspace(target) {
        case let .success(rawWorkspaceID):
            return controller.performWorkspaceTargetAction(action, onWorkspaceNamed: rawWorkspaceID)
        case let .failure(result):
            return result
        }
    }
}
