// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    func removeWindow(token: WindowToken, from workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let leaf = state.leafByToken[token],
              let tile = leaf.tile,
              let memberIndex = tile.memberIndex(for: token)
        else { return }

        if tile.members.count > 1 {
            _ = tile.remove(at: memberIndex)
            state.leafByToken.removeValue(forKey: token)
        } else {
            let successorToken = state.selectedNodeId == leaf.id
                ? removalSuccessorToken(for: token, in: workspaceId)
                : nil
            state.leafByToken.removeValue(forKey: token)
            leaf.kind = .leaf(tile: nil)
            leaf.cachedContentFrame = nil
            state.tileCount -= 1
            cleanupAfterRemoval(leaf, state: state, successorToken: successorToken)
        }
        state.pendingMovementFrameSeeds.removeValue(forKey: token)
        if state.leafByToken.isEmpty {
            state.selectedNodeId = nil
        }
        state.excludedTokens.remove(token)
        releaseConstraintsIfUntracked(token)
    }
}
