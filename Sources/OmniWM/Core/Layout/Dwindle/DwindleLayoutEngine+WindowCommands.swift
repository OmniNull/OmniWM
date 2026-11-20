// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    func moveFocus(direction: Direction, in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId) else { return nil }
        guard let current = selectedNode(in: workspaceId),
              let currentTile = current.tile,
              let currentMember = visibleMember(in: currentTile, excluding: state.excludedTokens)
        else {
            if let firstLeaf = firstVisibleLeaf(in: state.root, excluding: state.excludedTokens),
               let tile = firstLeaf.tile,
               let member = visibleMember(in: tile, excluding: state.excludedTokens)
            {
                state.selectedNodeId = firstLeaf.id
                return member.token
            }
            return nil
        }

        guard let neighborHandle = findGeometricNeighbor(
            from: currentMember.token,
            direction: direction,
            in: workspaceId
        ) else {
            return nil
        }

        if let neighborNode = findNode(for: neighborHandle, in: workspaceId) {
            existingState(for: workspaceId)?.selectedNodeId = neighborNode.id
        }
        return neighborHandle
    }

    func swapWindowOutcome(direction: Direction, in workspaceId: WorkspaceDescriptor.ID) -> WindowMoveOutcome {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let current = selectedNode(in: workspaceId),
              let currentTile = current.tile
        else {
            return .blocked
        }

        guard let currentHandle = visibleMember(
            in: currentTile,
            excluding: state.excludedTokens
        )?.token else {
            return .blocked
        }

        guard let neighborHandle = findGeometricNeighbor(
            from: currentHandle,
            direction: direction,
            in: workspaceId
        ) else {
            return .atWorkspaceEdge
        }

        return swapLeafTiles(of: currentHandle, and: neighborHandle, in: workspaceId)
            ? .movedWithinWorkspace
            : .atWorkspaceEdge
    }

    @discardableResult
    func swapLeafTiles(
        of token: WindowToken,
        and otherToken: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let current = state.leafByToken[token],
              let currentTile = current.tile,
              let neighbor = state.leafByToken[otherToken],
              let neighborTile = neighbor.tile,
              current !== neighbor
        else {
            return false
        }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let currentMovementFrameSeed = current.hasActiveAnimations(at: now)
            ? current.presentedFrame(at: now)
            : nil
        let neighborMovementFrameSeed = neighbor.hasActiveAnimations(at: now)
            ? neighbor.presentedFrame(at: now)
            : nil

        current.kind = .leaf(tile: neighborTile)
        neighbor.kind = .leaf(tile: currentTile)

        let currentCachedFrame = current.cachedFrame
        current.cachedFrame = neighbor.cachedFrame
        neighbor.cachedFrame = currentCachedFrame
        let currentContentFrame = current.cachedContentFrame
        current.cachedContentFrame = neighbor.cachedContentFrame
        neighbor.cachedContentFrame = currentContentFrame

        current.clearAnimations()
        neighbor.clearAnimations()

        for member in currentTile.members {
            state.leafByToken[member.token] = neighbor
        }
        for member in neighborTile.members {
            state.leafByToken[member.token] = current
        }
        if state.pendingMovementFrameSeeds[currentTile.activeToken] == nil,
           let currentMovementFrameSeed
        {
            state.pendingMovementFrameSeeds[token] = currentMovementFrameSeed
        }
        if state.pendingMovementFrameSeeds[neighborTile.activeToken] == nil,
           let neighborMovementFrameSeed
        {
            state.pendingMovementFrameSeeds[neighborTile.activeToken] = neighborMovementFrameSeed
        }

        state.selectedNodeId = neighbor.id
        return true
    }

    @discardableResult
    func toggleOrientation(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let selected = selectedNode(in: workspaceId),
              let parent = firstVisibleSplitAncestor(
                  from: selected,
                  excluding: state.excludedTokens
              )?.split,
              case let .split(orientation, ratio) = parent.kind
        else {
            return false
        }

        parent.kind = .split(orientation: orientation.perpendicular, ratio: ratio)
        return true
    }

    func toggleFullscreen(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let selected = selectedNode(in: workspaceId),
              let tile = selected.tile,
              let handle = visibleMember(in: tile, excluding: state.excludedTokens)?.token
        else {
            return nil
        }

        _ = tile.toggleFullscreen(for: handle)
        return handle
    }

    func toggleFullscreen(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let tile = state.leafByToken[token]?.tile,
              visibleMember(in: tile, excluding: state.excludedTokens)?.token == token
        else { return false }
        _ = tile.toggleFullscreen(for: token)
        return true
    }
}
