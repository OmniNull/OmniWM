// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension DwindleLayoutHandler {
    func markIncomingWindowForStacking(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) {
        guard let controller,
              controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh,
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .dwindle
        else { return }
        stackableIncomingTokens.insert(token)
    }

    func forgetIncomingWindow(_ token: WindowToken) {
        stackableIncomingTokens.remove(token)
    }

    func claimIncomingStackingTokens(_ windowTokens: [WindowToken]) -> Set<WindowToken> {
        guard !stackableIncomingTokens.isEmpty else { return [] }
        let claimed = stackableIncomingTokens.intersection(windowTokens)
        stackableIncomingTokens.subtract(claimed)
        return claimed
    }
}
