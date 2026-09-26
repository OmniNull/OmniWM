// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension DwindleLayoutHandler {
    func markIncomingWindowForStacking(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) {
        guard let controller,
              controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh,
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .dwindle
        else { return }
        stackableIncomingWorkspaceByToken[token] = workspaceId
    }

    func forgetIncomingWindow(_ token: WindowToken) {
        stackableIncomingWorkspaceByToken.removeValue(forKey: token)
    }

    func claimIncomingStackingTokens(
        _ windowTokens: [WindowToken],
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Set<WindowToken> {
        guard !stackableIncomingWorkspaceByToken.isEmpty else { return [] }
        var claimed = Set<WindowToken>()
        for token in windowTokens {
            guard let markedWorkspaceId = stackableIncomingWorkspaceByToken.removeValue(forKey: token) else {
                continue
            }
            if markedWorkspaceId == workspaceId {
                claimed.insert(token)
            }
        }
        return claimed
    }
}
