// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum WorkspaceTargetAction: Equatable, Sendable {
    case focus
    case moveToMonitor(Direction, force: Bool)
    case rename(String)

    var hasValidArguments: Bool {
        guard case let .rename(displayName) = self else { return true }
        return !displayName.contains(where: \.isNewline)
    }
}

extension WMController {
    func performWorkspaceTargetAction(
        _ action: WorkspaceTargetAction,
        onWorkspaceNamed rawWorkspaceID: String
    ) -> ExternalCommandResult {
        switch action {
        case .focus:
            if let currentWorkspace = activeWorkspace(),
               currentWorkspace.name == rawWorkspaceID,
               workspaceNavigationHandler.canSkipSwitch(toVisibleWorkspace: currentWorkspace.id)
            {
                return .noChange
            }
            return windowActionHandler.focusWorkspaceFromBar(named: rawWorkspaceID) ? .executed : .notFound
        case let .moveToMonitor(direction, force):
            guard let workspaceId = workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false),
                  let outcome = workspaceNavigationHandler.moveWorkspaceToMonitor(
                      workspaceId,
                      direction: direction,
                      force: force
                  )
            else {
                return .notFound
            }
            return switch outcome.status {
            case .executed: .executed
            case .conflict: .workspaceAssignmentConflict
            case .stateConflict: .workspaceStateConflict
            case .notFound: .notFound
            }
        case let .rename(displayName):
            return setWorkspaceDisplayName(displayName, forWorkspaceNamed: rawWorkspaceID)
        }
    }
}
