// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    @discardableResult
    func groupWindow(direction: Direction, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let token = projectedActiveToken(in: workspaceId) else { return false }
        return groupWindow(token, direction: direction, in: workspaceId)
    }

    @discardableResult
    func groupWindow(
        _ token: WindowToken,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let neighborToken = findGeometricNeighbor(
            from: token,
            direction: direction,
            in: workspaceId
        ) else {
            return false
        }
        return groupWindow(token, into: neighborToken, in: workspaceId)
    }

    @discardableResult
    func groupWindow(
        _ token: WindowToken,
        into neighborToken: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let sourceLeaf = state.leafByToken[token],
              let sourceTile = sourceLeaf.tile,
              let sourceMemberIndex = sourceTile.memberIndex(for: token),
              neighborToken != token,
              let destinationLeaf = state.leafByToken[neighborToken],
              destinationLeaf.id != sourceLeaf.id,
              let destinationTile = destinationLeaf.tile
        else {
            return false
        }
        let movementFrameSeed = sourceLeaf.presentedFrame(
            at: animationClock?.now() ?? CACurrentMediaTime()
        )

        let sourceParent = sourceLeaf.parent
        let destinationWillPromote = sourceTile.members.count == 1
            && sourceLeaf.sibling()?.id == destinationLeaf.id
        let member = detachMember(
            at: sourceMemberIndex,
            from: sourceLeaf,
            tile: sourceTile,
            state: state
        )
        let updatedDestinationLeaf = destinationWillPromote ? sourceParent ?? destinationLeaf : destinationLeaf

        destinationTile.insertAfterActive(member)
        state.leafByToken[token] = updatedDestinationLeaf
        state.selectedNodeId = updatedDestinationLeaf.id
        if state.pendingMovementFrameSeeds[token] == nil {
            state.pendingMovementFrameSeeds[token] = movementFrameSeed
        }
        return true
    }

    @discardableResult
    func ungroupWindow(direction: Direction, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let token = projectedActiveToken(in: workspaceId) else { return false }
        return ungroupWindow(token, direction: direction, in: workspaceId)
    }

    @discardableResult
    func ungroupWindow(
        _ token: WindowToken,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let leaf = state.leafByToken[token],
              let tile = leaf.tile,
              tile.members.count > 1,
              let memberIndex = tile.memberIndex(for: token)
        else {
            return false
        }
        let movementFrameSeed = leaf.presentedFrame(
            at: animationClock?.now() ?? CACurrentMediaTime()
        )

        _ = tile.activate(token)
        let member = tile.remove(at: memberIndex)
        state.leafByToken.removeValue(forKey: token)
        let newTile = DwindleTile(token: member.token, fullscreen: member.isFullscreen)
        let newLeaf = splitLeaf(
            leaf,
            tiles: (new: newTile, existing: tile),
            state: state,
            activeWindowFrame: leaf.cachedContentFrame ?? leaf.cachedFrame,
            preselectedDirection: direction
        )
        state.leafByToken[token] = newLeaf
        state.selectedNodeId = newLeaf.id
        if state.pendingMovementFrameSeeds[token] == nil {
            state.pendingMovementFrameSeeds[token] = movementFrameSeed
        }
        return true
    }

    func consumePendingMovementFrameSeeds(
        in workspaceId: WorkspaceDescriptor.ID,
        oldFrames: inout [WindowToken: CGRect],
        previousTargetFrames: inout [WindowToken: CGRect]
    ) {
        guard let state = existingState(for: workspaceId), !state.pendingMovementFrameSeeds.isEmpty else { return }
        for (token, frame) in state.pendingMovementFrameSeeds {
            oldFrames[token] = frame
            previousTargetFrames[token] = frame
        }
        state.pendingMovementFrameSeeds.removeAll(keepingCapacity: true)
    }

    @discardableResult
    func moveGroupMember(
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let token = projectedActiveToken(in: workspaceId) else { return false }
        return moveGroupMember(token, direction: direction, in: workspaceId)
    }

    @discardableResult
    func moveGroupMember(
        _ token: WindowToken,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        let offset: Int
        switch direction {
        case .up:
            offset = -1
        case .down:
            offset = 1
        case .left,
             .right:
            return false
        }
        guard let state = existingState(for: workspaceId),
              !state.excludedTokens.contains(token),
              let tile = state.leafByToken[token]?.tile,
              let sourceIndex = tile.memberIndex(for: token)
        else {
            return false
        }
        let visibleIndices = tile.members.indices.filter {
            !state.excludedTokens.contains(tile.members[$0].token)
        }
        guard let projectedIndex = visibleIndices.firstIndex(of: sourceIndex) else { return false }
        let destinationIndex = projectedIndex + offset
        guard visibleIndices.indices.contains(destinationIndex) else { return false }
        return tile.move(token, to: visibleIndices[destinationIndex])
    }

    private func detachMember(
        at memberIndex: Int,
        from leaf: DwindleNode,
        tile: DwindleTile,
        state: DwindleWorkspaceState
    ) -> DwindleTileMember {
        let member: DwindleTileMember
        if tile.members.count > 1 {
            member = tile.remove(at: memberIndex)
        } else {
            member = tile.members[memberIndex]
            leaf.kind = .leaf(tile: nil)
            leaf.cachedContentFrame = nil
            state.tileCount -= 1
            cleanupAfterRemoval(leaf, state: state)
        }
        state.leafByToken.removeValue(forKey: member.token)
        return member
    }

    func cleanupAfterRemoval(
        _ node: DwindleNode,
        state: DwindleWorkspaceState,
        successorToken: WindowToken? = nil
    ) {
        guard let parent = node.parent, let sibling = node.sibling() else { return }

        node.detach()

        parent.kind = sibling.kind
        parent.children = sibling.children
        for child in parent.children {
            child.parent = parent
        }

        if let tile = parent.tile {
            for member in tile.members {
                state.leafByToken[member.token] = parent
            }
        }

        if state.selectedNodeId == node.id {
            let successor = successorToken.flatMap { state.leafByToken[$0] }
            state.selectedNodeId = (successor ?? parent.descendToFirstLeaf()).id
        }

        let selectionResolves = state.selectedNodeId.flatMap { findNodeById($0, in: state.root) } != nil
        if !selectionResolves {
            state.selectedNodeId = parent.descendToFirstLeaf().id
        }
    }
}
