// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    func canInsertAtWorkspaceEdge(token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let state = existingState(for: workspaceId),
              let source = state.leafByToken[token],
              !state.excludedTokens.contains(token),
              !isWindowFullscreen(token, in: workspaceId)
        else { return false }
        var hasPeer = false
        for leaf in state.root.collectAllLeaves() {
            guard let tile = leaf.tile,
                  let member = visibleMember(in: tile, excluding: state.excludedTokens)
            else { continue }
            if member.isFullscreen { return false }
            if leaf !== source { hasPeer = true }
        }
        return hasPeer
    }

    @discardableResult
    func insertLeafTile(
        of token: WindowToken,
        atWorkspaceEdge direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard canInsertAtWorkspaceEdge(token: token, in: workspaceId),
              let state = existingState(for: workspaceId),
              let source = state.leafByToken[token]
        else { return false }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        for leaf in state.root.collectAllLeaves() {
            guard let tile = leaf.tile, let frame = leaf.presentedFrame(at: now) else { continue }
            for member in tile.members where state.pendingMovementFrameSeeds[member.token] == nil {
                state.pendingMovementFrameSeeds[member.token] = frame
            }
        }
        cleanupAfterRemoval(source, state: state)

        let root = state.root
        let remainder = DwindleNode(kind: root.kind)
        for child in root.children {
            remainder.appendChild(child)
        }
        if let tile = remainder.tile {
            for member in tile.members {
                state.leafByToken[member.token] = remainder
            }
        }

        root.kind = .split(orientation: direction.dwindleOrientation, ratio: 1)
        if direction == .left || direction == .down {
            root.replaceChildren(first: source, second: remainder)
        } else {
            root.replaceChildren(first: remainder, second: source)
        }
        state.selectedNodeId = source.id
        return true
    }
}
