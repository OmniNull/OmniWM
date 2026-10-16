// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    @discardableResult
    func insertLeafTile(
        of token: WindowToken,
        beside targetToken: WindowToken,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let source = state.leafByToken[token],
              let tile = source.tile,
              let target = state.leafByToken[targetToken],
              let targetTile = target.tile,
              source !== target,
              !state.excludedTokens.contains(token),
              !state.excludedTokens.contains(targetToken),
              !isWindowFullscreen(token, in: workspaceId),
              !isWindowFullscreen(targetToken, in: workspaceId),
              let destination = source.sibling() === target ? source.parent : target
        else { return false }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        for node in [source, target, source.sibling()] {
            guard let node, let affectedTile = node.tile, let frame = node.presentedFrame(at: now) else { continue }
            for member in affectedTile.members where state.pendingMovementFrameSeeds[member.token] == nil {
                state.pendingMovementFrameSeeds[member.token] = frame
            }
        }
        source.kind = .leaf(tile: nil)
        source.cachedContentFrame = nil
        state.tileCount -= 1
        cleanupAfterRemoval(source, state: state)

        let inserted = splitLeaf(
            destination,
            tiles: (new: tile, existing: targetTile),
            state: state,
            activeWindowFrame: nil,
            preselectedDirection: direction,
            splitRatio: 1
        )
        for member in tile.members {
            state.leafByToken[member.token] = inserted
        }
        state.selectedNodeId = inserted.id
        return true
    }
}
