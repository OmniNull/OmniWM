// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct DwindleTransferredTile {
    let tile: DwindleTile
    let excludedTokens: Set<WindowToken>

    init(tile: DwindleTile, excludedTokens: Set<WindowToken> = []) {
        self.tile = tile
        self.excludedTokens = excludedTokens
    }

    init(token: WindowToken, excluded: Bool = false) {
        self.init(tile: DwindleTile(token: token), excludedTokens: excluded ? [token] : [])
    }
}

enum DwindleTransferPlacement: Equatable {
    case beside(WindowToken, Direction)
    case workspaceEdge(Direction)
    case splitBoundary(DwindleNodeId)
    case defaultPlacement
}

extension DwindleLayoutEngine {
    func visibleTiles(in workspaceId: WorkspaceDescriptor.ID) -> (any: Bool, fullscreen: Bool) {
        guard let state = existingState(for: workspaceId) else { return (false, false) }
        var hasVisibleTile = false
        for leaf in state.root.collectAllLeaves() {
            guard let member = visibleMember(in: leaf.tile, excluding: state.excludedTokens) else { continue }
            if member.isFullscreen { return (true, true) }
            hasVisibleTile = true
        }
        return (hasVisibleTile, false)
    }

    func tile(containing token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> DwindleTile? {
        existingState(for: workspaceId)?.leafByToken[token]?.tile
    }

    func transferTile(
        containing token: WindowToken,
        wholeTile: Bool,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> DwindleTransferredTile? {
        guard let state = existingState(for: workspaceId), let tile = state.leafByToken[token]?.tile else {
            return nil
        }
        guard wholeTile || tile.members.count == 1 else {
            return DwindleTransferredTile(token: token, excluded: state.excludedTokens.contains(token))
        }
        return DwindleTransferredTile(
            tile: tile,
            excludedTokens: state.excludedTokens.intersection(tile.members.map(\.token))
        )
    }

    func detachForTransfer(
        token: WindowToken,
        wholeTile: Bool,
        from workspaceId: WorkspaceDescriptor.ID
    ) -> DwindleTransferredTile? {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let leaf = state.leafByToken[token],
              let tile = leaf.tile,
              let memberIndex = tile.memberIndex(for: token)
        else { return nil }

        seedMovementFramesFromPresentedLeaves(in: state)
        guard wholeTile || tile.members.count == 1 else {
            let detached = detachTransferredMember(token, at: memberIndex, in: tile, state: state)
            return DwindleTransferredTile(token: detached.member.token, excluded: detached.excluded)
        }
        return detachTransferredTile(leaf, tile: consume tile, token: token, in: workspaceId, state: state)
    }

    func detachForHistoryTransfer(
        token: WindowToken,
        wholeTile: Bool,
        from workspaceId: WorkspaceDescriptor.ID
    ) -> DwindleHistoryArrival? {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId), let leaf = state.leafByToken[token],
              let tile = leaf.tile, let memberIndex = tile.memberIndex(for: token)
        else { return nil }
        seedMovementFramesFromPresentedLeaves(in: state)
        guard wholeTile || tile.members.count == 1 else {
            let detached = detachTransferredMember(token, at: memberIndex, in: tile, state: state)
            return .member(detached.member, excluded: detached.excluded)
        }
        return .tile(detachTransferredTile(leaf, tile: consume tile, token: token, in: workspaceId, state: state))
    }

    private func detachTransferredMember(
        _ token: WindowToken,
        at index: Int,
        in tile: DwindleTile,
        state: DwindleWorkspaceState
    ) -> (member: DwindleTileMember, excluded: Bool) {
        let member = tile.remove(at: index)
        state.leafByToken.removeValue(forKey: token)
        state.pendingMovementFrameSeeds.removeValue(forKey: token)
        return (member, state.excludedTokens.remove(token) != nil)
    }

    private func detachTransferredTile(
        _ leaf: DwindleNode,
        tile: consuming DwindleTile,
        token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        state: DwindleWorkspaceState
    ) -> DwindleTransferredTile {
        let successorToken = state.selectedNodeId == leaf.id
            ? removalSuccessorToken(for: token, in: workspaceId)
            : nil
        let tokens = tile.members.map(\.token)
        let excluded = state.excludedTokens.intersection(tokens)
        for member in tokens {
            state.leafByToken.removeValue(forKey: member)
            state.pendingMovementFrameSeeds.removeValue(forKey: member)
            state.excludedTokens.remove(member)
        }
        leaf.kind = .leaf(tile: nil)
        leaf.cachedContentFrame = nil
        state.tileCount -= 1
        cleanupAfterRemoval(leaf, state: state, successorToken: successorToken)
        if state.leafByToken.isEmpty {
            state.selectedNodeId = nil
        }
        return DwindleTransferredTile(tile: tile, excludedTokens: excluded)
    }

    func attachTransferredTile(
        _ transferred: DwindleTransferredTile,
        placement: DwindleTransferPlacement,
        in workspaceId: WorkspaceDescriptor.ID,
        activeWindowFrame: CGRect? = nil
    ) {
        assertSanctionedMutation()
        let state = ensureState(for: workspaceId)
        seedMovementFramesFromPresentedLeaves(in: state)
        _ = exitFullscreen(in: workspaceId)
        let tile = transferred.tile
        let leaf: DwindleNode = switch placement {
        case let .beside(targetToken, direction):
            state.leafByToken[targetToken].map { target in
                splitLeaf(
                    target,
                    tiles: (new: tile, existing: target.tile),
                    state: state,
                    activeWindowFrame: nil,
                    preselectedDirection: direction,
                    splitRatio: 1
                )
            } ?? attachAtDefaultPlacement(tile, state: state, in: workspaceId, activeWindowFrame: activeWindowFrame)
        case let .workspaceEdge(direction) where state.tileCount > 0:
            attachAtWorkspaceEdge(tile, direction: direction, state: state)
        case let .splitBoundary(splitId):
            attachAtSplitBoundary(tile, splitId: splitId, state: state)
                ?? attachAtDefaultPlacement(tile, state: state, in: workspaceId, activeWindowFrame: activeWindowFrame)
        case .workspaceEdge,
             .defaultPlacement:
            attachAtDefaultPlacement(tile, state: state, in: workspaceId, activeWindowFrame: activeWindowFrame)
        }
        for member in tile.members {
            state.leafByToken[member.token] = leaf
        }
        state.excludedTokens.formUnion(transferred.excludedTokens)
        state.selectedNodeId = leaf.id
    }

    func attachTransferredMember(
        _ arrival: consuming DwindleHistoryArrival,
        to target: WindowToken,
        at index: Int,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let leaf = state.leafByToken[target], let tile = leaf.tile,
              !state.excludedTokens.contains(target),
              tile.member(for: target)?.isFullscreen == false
        else { return false }
        let member: DwindleTileMember
        let excluded: Bool
        switch consume arrival {
        case let .member(incoming, incomingExcluded):
            member = incoming
            excluded = incomingExcluded
        case let .tile(transferred):
            guard transferred.tile.members.count == 1 else { return false }
            member = transferred.tile.activeMember
            excluded = transferred.excludedTokens.contains(member.token)
        }
        guard state.leafByToken[member.token] == nil else { return false }
        seedMovementFramesFromPresentedLeaves(in: state)
        tile.insert(member, at: index)
        state.leafByToken[member.token] = leaf
        if excluded { state.excludedTokens.insert(member.token) }
        state.selectedNodeId = leaf.id
        return true
    }

    func replaceSlot(
        of partnerToken: WindowToken,
        wholeTile: Bool,
        with incoming: DwindleTransferredTile,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> DwindleTransferredTile? {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let leaf = state.leafByToken[partnerToken],
              let tile = leaf.tile
        else { return nil }

        let outgoing: DwindleTransferredTile
        if wholeTile || tile.members.count == 1 {
            let tokens = tile.members.map(\.token)
            outgoing = DwindleTransferredTile(tile: tile, excludedTokens: state.excludedTokens.intersection(tokens))
            for member in tokens {
                state.leafByToken.removeValue(forKey: member)
                state.pendingMovementFrameSeeds.removeValue(forKey: member)
                state.excludedTokens.remove(member)
            }
            leaf.kind = .leaf(tile: incoming.tile)
        } else {
            guard incoming.tile.members.count == 1 else { return nil }
            let incomingToken = incoming.tile.activeToken
            let excluded = state.excludedTokens.remove(partnerToken) != nil
            outgoing = DwindleTransferredTile(token: partnerToken, excluded: excluded)
            state.leafByToken.removeValue(forKey: partnerToken)
            state.pendingMovementFrameSeeds.removeValue(forKey: partnerToken)
            tile.rekey(from: partnerToken, to: incomingToken)
        }
        for member in leaf.tile?.members ?? [] {
            state.leafByToken[member.token] = leaf
        }
        state.excludedTokens.formUnion(incoming.excludedTokens)
        state.selectedNodeId = leaf.id
        return outgoing
    }

    private func attachAtWorkspaceEdge(
        _ tile: DwindleTile,
        direction: Direction,
        state: DwindleWorkspaceState
    ) -> DwindleNode {
        let leaf = DwindleNode(kind: .leaf(tile: tile))
        let root = state.root
        let remainder = DwindleNode(kind: root.kind)
        for child in root.children {
            remainder.appendChild(child)
        }
        for member in remainder.tile?.members ?? [] {
            state.leafByToken[member.token] = remainder
        }
        root.kind = .split(orientation: direction.dwindleOrientation, ratio: 1)
        if direction == .left || direction == .down {
            root.replaceChildren(first: leaf, second: remainder)
        } else {
            root.replaceChildren(first: remainder, second: leaf)
        }
        state.tileCount += 1
        return leaf
    }

    private func attachAtSplitBoundary(
        _ tile: DwindleTile,
        splitId: DwindleNodeId,
        state: DwindleWorkspaceState
    ) -> DwindleNode? {
        guard let split = findNodeById(splitId, in: state.root),
              let orientation = split.splitOrientation,
              let first = split.firstChild(), let second = split.secondChild()
        else { return nil }
        let leaf = DwindleNode(kind: .leaf(tile: tile))
        insertLeaf(leaf, between: first, and: second, orientation: orientation, in: split)
        state.tileCount += 1
        return leaf
    }

    private func attachAtDefaultPlacement(
        _ tile: DwindleTile,
        state: DwindleWorkspaceState,
        in workspaceId: WorkspaceDescriptor.ID,
        activeWindowFrame: CGRect?
    ) -> DwindleNode {
        if case .leaf(nil) = state.root.kind {
            state.root.kind = .leaf(tile: tile)
            state.tileCount = 1
            return state.root
        }
        let target = selectedNode(in: workspaceId).flatMap { $0.isLeaf ? $0 : nil }
            ?? state.root.descendToFirstLeaf()
        let leaf = splitLeaf(
            target,
            tiles: (new: tile, existing: target.tile),
            state: state,
            activeWindowFrame: activeWindowFrame,
            preselectedDirection: state.preselection
        )
        state.preselection = nil
        return leaf
    }
}
