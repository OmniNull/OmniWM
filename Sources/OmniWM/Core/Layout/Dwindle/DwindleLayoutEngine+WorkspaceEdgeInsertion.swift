// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension DwindleLayoutEngine {
    func canInsertAtWorkspaceEdge(token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let state = existingState(for: workspaceId),
              let source = state.leafByToken[token],
              !state.excludedTokens.contains(token),
              !isWindowFullscreen(token, in: workspaceId)
        else { return false }
        let status = insertionPeerStatus(in: state.root, source: source, excluding: state.excludedTokens)
        return status.hasPeer && !status.hasFullscreen
    }

    func insertionPeerStatus(
        in node: DwindleNode,
        source: DwindleNode,
        excluding excludedTokens: Set<WindowToken>
    ) -> (hasPeer: Bool, hasFullscreen: Bool) {
        if node.isLeaf {
            guard let member = visibleMember(in: node.tile, excluding: excludedTokens) else { return (false, false) }
            return (node !== source, member.isFullscreen)
        }
        var hasPeer = false
        for child in node.children {
            let status = insertionPeerStatus(in: child, source: source, excluding: excludedTokens)
            if status.hasFullscreen { return (false, true) }
            hasPeer = hasPeer || status.hasPeer
        }
        return (hasPeer, false)
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

        seedMovementFramesFromPresentedLeaves(in: state)
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
