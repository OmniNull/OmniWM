// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

private func restoreHistoryChildren(
    of node: DwindleNode,
    first: DwindleNode? = nil,
    second: DwindleNode? = nil
) {
    for child in node.children where child.parent === node { child.parent = nil }
    node.children.removeAll(keepingCapacity: true)
    if let first, let second {
        first.parent = node
        second.parent = node
        node.children.append(first)
        node.children.append(second)
    }
}

struct DwindleLayoutReplay: ~Copyable {
    private var nodes: [DwindleNodeId: DwindleNode] = [:]
    private var tiles: [DwindleTileId: DwindleTile] = [:]
    private var tileOrder: [DwindleTileId] = []
    private var nextTile = 0
    private var present: Set<WindowToken> = []
    private var historical: Set<WindowToken> = []

    init(root: DwindleNode, snapshot: borrowing DwindleLayoutSnapshot) {
        for index in snapshot.members.indices { historical.insert(snapshot.members[index].token) }
        collect(root)
    }

    init(
        root: DwindleNode,
        snapshot: borrowing DwindleLayoutSnapshot,
        arrivals: borrowing[DwindleHistoryArrival]
    ) {
        self.init(root: root, snapshot: snapshot)
        for index in arrivals.indices {
            switch arrivals[index] {
            case let .member(member, _):
                present.insert(member.token)
            case let .tile(transferred):
                let tile = transferred.tile
                if tiles[tile.id] == nil { tileOrder.append(tile.id) }
                tiles[tile.id] = tile
                for member in tile.members { present.insert(member.token) }
            }
        }
    }

    private mutating func collect(_ node: DwindleNode) {
        nodes[node.id] = node
        if let tile = node.tile {
            tiles[tile.id] = tile
            tileOrder.append(tile.id)
            for member in tile.members { present.insert(member.token) }
        }
        for child in node.children { collect(child) }
    }

    mutating func restore(
        _ index: Int,
        from snapshot: borrowing DwindleLayoutSnapshot
    ) -> DwindleNode? {
        let saved = snapshot.nodes[index]
        guard let orientation = saved.orientation,
              let firstIndex = saved.firstChild, let secondIndex = saved.secondChild
        else { return restoreLeaf(saved, from: snapshot) }
        let first = restore(firstIndex, from: snapshot)
        let second = restore(secondIndex, from: snapshot)
        guard let first else { return second }
        guard let second else { return first }
        let node = nodes.removeValue(forKey: saved.id) ?? DwindleNode(kind: .leaf(tile: nil), id: saved.id)
        node.kind = .split(orientation: orientation, ratio: saved.ratio)
        if node.firstChild() !== first || node.secondChild() !== second {
            restoreHistoryChildren(of: node, first: first, second: second)
        }
        node.edgeExpansion = saved.expansion
        node.cachedContentFrame = nil
        node.clearAnimations()
        return node
    }

    private mutating func restoreLeaf(
        _ saved: DwindleLayoutSnapshot.Node,
        from snapshot: borrowing DwindleLayoutSnapshot
    ) -> DwindleNode? {
        guard let tileId = saved.tileId else { return nil }
        let existing = tiles.removeValue(forKey: tileId)
        var members: [DwindleTileMember] = []
        members.reserveCapacity(saved.members.count)
        for index in saved.members where present.contains(snapshot.members[index].token) {
            members.append(snapshot.members[index])
        }
        if let existing {
            for member in existing.members where !historical.contains(member.token) { members.append(member) }
        }
        guard let first = members.first else { return nil }
        let tile = existing ?? DwindleTile(token: first.token, fullscreen: first.isFullscreen, id: tileId)
        tile.restoreMembers(members, activeToken: saved.active)
        let node = nodes.removeValue(forKey: saved.id) ?? DwindleNode(kind: .leaf(tile: nil), id: saved.id)
        if !node.children.isEmpty {
            restoreHistoryChildren(of: node)
        }
        if node.tile !== tile { node.kind = .leaf(tile: tile) }
        node.edgeExpansion = nil
        node.cachedContentFrame = nil
        node.clearAnimations()
        return node
    }

    mutating func nextPreservedTile() -> DwindleTile? {
        while nextTile < tileOrder.count {
            let id = tileOrder[nextTile]
            nextTile += 1
            guard let tile = tiles.removeValue(forKey: id) else { continue }
            var members: [DwindleTileMember] = []
            for member in tile.members where !historical.contains(member.token) { members.append(member) }
            guard !members.isEmpty else { continue }
            tile.restoreMembers(members, activeToken: tile.activeToken)
            return tile
        }
        return nil
    }
}

extension DwindleLayoutEngine {
    func restoreLayoutSnapshot(
        _ snapshot: borrowing DwindleLayoutSnapshot,
        in workspaceId: WorkspaceDescriptor.ID,
        at time: TimeInterval? = nil
    ) {
        guard let state = existingState(for: workspaceId), !snapshot.nodes.isEmpty else { return }
        if snapshot.canRestoreInPlace(state.root) {
            snapshot.restoreInPlace(state.root)
            finishHistoryRestore(snapshot, in: workspaceId, state: state)
            return
        }
        seedMovementFramesFromPresentedLeaves(in: state, at: time)
        var replay = DwindleLayoutReplay(root: state.root, snapshot: snapshot)
        restoreLayoutSnapshot(snapshot, replay: &replay, in: workspaceId, state: state)
    }

    func restoreLayoutSnapshot(
        _ snapshot: borrowing DwindleLayoutSnapshot,
        in workspaceId: WorkspaceDescriptor.ID,
        arrivals: borrowing [DwindleHistoryArrival],
        at time: TimeInterval? = nil
    ) {
        guard !arrivals.isEmpty else {
            restoreLayoutSnapshot(snapshot, in: workspaceId, at: time)
            return
        }
        let state = ensureState(for: workspaceId)
        seedMovementFramesFromPresentedLeaves(in: state, at: time)
        for index in arrivals.indices { arrivals[index].restoreExclusions(into: &state.excludedTokens) }
        var replay = DwindleLayoutReplay(root: state.root, snapshot: snapshot, arrivals: arrivals)
        restoreLayoutSnapshot(snapshot, replay: &replay, in: workspaceId, state: state)
    }

    private func restoreLayoutSnapshot(
        _ snapshot: borrowing DwindleLayoutSnapshot,
        replay: inout DwindleLayoutReplay,
        in workspaceId: WorkspaceDescriptor.ID,
        state: DwindleWorkspaceState
    ) {
        let restored = replay.restore(0, from: snapshot)
        installHistoryRoot(restored, in: state)
        while let tile = replay.nextPreservedTile() {
            if state.root.tile == nil, state.root.children.isEmpty {
                state.root.kind = .leaf(tile: tile)
            } else {
                var last = state.root
                while let second = last.secondChild() { last = second }
                _ = splitLeaf(
                    last, tiles: (new: tile, existing: last.tile), state: state,
                    activeWindowFrame: nil, preselectedDirection: .right
                )
            }
        }
        state.leafByToken.removeAll(keepingCapacity: true)
        state.tileCount = 0
        indexLeaves(from: state.root, into: state)
        finishHistoryRestore(snapshot, in: workspaceId, state: state)
    }

    private func finishHistoryRestore(
        _ snapshot: borrowing DwindleLayoutSnapshot,
        in workspaceId: WorkspaceDescriptor.ID,
        state: DwindleWorkspaceState
    ) {
        if let selected = snapshot.selected, let leaf = state.leafByToken[selected] {
            state.selectedNodeId = leaf.id
        } else {
            state.selectedNodeId = state.tileCount > 0 ? state.root.descendToFirstLeaf().id : nil
        }
        state.preselection = snapshot.preselection
        validateHistoryExpansions(state.root, in: workspaceId)
    }

    private func installHistoryRoot(_ restored: DwindleNode?, in state: DwindleWorkspaceState) {
        guard restored !== state.root else { return }
        let root = state.root
        restoreHistoryChildren(of: root, first: restored?.firstChild(), second: restored?.secondChild())
        root.kind = restored?.kind ?? .leaf(tile: nil)
        root.edgeExpansion = nil
        root.cachedContentFrame = nil
        root.clearAnimations()
    }

    private func validateHistoryExpansions(_ node: DwindleNode, in workspaceId: WorkspaceDescriptor.ID) {
        if let saved = node.edgeExpansion, !historyExpansion(saved, isValidFor: node, in: workspaceId) {
            node.edgeExpansion = nil
        }
        for child in node.children { validateHistoryExpansions(child, in: workspaceId) }
    }

    private func historyExpansion(
        _ saved: DwindleEdgeExpansion,
        isValidFor node: DwindleNode,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let orientation = node.splitOrientation,
              let root = root(for: workspaceId), let leaf = findNodeById(saved.leafId, in: root),
              let match = controllingSplit(
                  from: leaf, orientation: orientation,
                  wantFirstChild: saved.edge == .right || saved.edge == .top, workspaceId: workspaceId
              )
        else { return false }
        return match.split === node && match.child.id == saved.childId && node.splitRatio == saved.expandedRatio
    }
}
