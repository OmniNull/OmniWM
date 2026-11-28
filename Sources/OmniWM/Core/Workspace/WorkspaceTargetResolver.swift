// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMAutomation
import OmniWMIPC

enum WorkspaceTargetResolutionError: Equatable, Error {
    case invalidTarget
    case ambiguousDisplayName
    case notFound
}

@MainActor
struct WorkspaceTargetResolver {
    let settings: SettingsStore
    let workspaceManager: WorkspaceManager

    func resolve(_ target: WorkspaceTarget) -> Result<String, WorkspaceTargetResolutionError> {
        switch target {
        case let .rawID(rawID):
            guard WorkspaceIDPolicy.normalizeRawID(rawID) != nil else {
                return .failure(.invalidTarget)
            }
            guard workspaceManager.workspaceId(for: rawID, createIfMissing: false) != nil else {
                return .failure(.notFound)
            }
            return .success(rawID)
        case let .displayName(displayName):
            guard !displayName.isEmpty else {
                return .failure(.invalidTarget)
            }

            let matches = settings.workspaces.configurations.filter {
                $0.effectiveDisplayName.caseInsensitiveCompare(displayName) == .orderedSame
            }

            guard !matches.isEmpty else {
                return .failure(.notFound)
            }
            guard matches.count == 1, let match = matches.first else {
                return .failure(.ambiguousDisplayName)
            }
            guard workspaceManager.workspaceId(for: match.name, createIfMissing: false) != nil else {
                return .failure(.notFound)
            }
            return .success(match.name)
        }
    }
}
