// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

private struct DwindleHistorySplit {
    let orientation: DwindleOrientation
    let ratio: CGFloat
    let returningFirst: Bool
}

extension DwindleLayoutEngine {
    func restoreLayoutAway(
        _ away: borrowing DwindleLayoutAway,
        arrivals: consuming [DwindleHistoryArrival],
        at time: TimeInterval? = nil
    ) {
        assertSanctionedMutation()
        guard !arrivals.isEmpty else { return }
        let state = ensureState(for: away.workspaceId)
        let selected = selectedNode(in: away.workspaceId)?.windowToken
        seedMovementFramesFromPresentedLeaves(in: state, at: time)
        for index in arrivals.indices { arrivals[index].restoreExclusions(into: &state.excludedTokens) }
        for index in away.snapshot.nodes.indices {
            let saved = away.snapshot.nodes[index]
            guard let tileId = saved.tileId else { continue }
            let returning = awayReturningMembers(saved, away: away, arrivals: arrivals)
            guard !returning.isEmpty else { continue }
            if let tile = survivingAwayTile(saved, away: away, state: state) {
                restoreAwayMembers(returning, to: tile, saved: saved, snapshot: away.snapshot)
            } else {
                let tile = existingAwayTile(with: tileId, arrivals: arrivals)
                    ?? DwindleTile(token: returning[0].token, id: tileId)
                tile.restoreMembers(returning, activeToken: saved.active)
                installAwayTile(tile, savedIndex: index, away: away, state: state)
            }
        }
        state.leafByToken.removeAll(keepingCapacity: true)
        state.tileCount = 0
        indexLeaves(from: state.root, into: state)
        if let selected, let leaf = state.leafByToken[selected] {
            state.selectedNodeId = leaf.id
        } else {
            reconcileProjectedSelection(in: state)
        }
    }

    private func awayReturningMembers(
        _ saved: DwindleLayoutSnapshot.Node,
        away: borrowing DwindleLayoutAway,
        arrivals: borrowing [DwindleHistoryArrival]
    ) -> [DwindleTileMember] {
        var members: [DwindleTileMember] = []
        for index in saved.members {
            let member = away.snapshot.members[index]
            if away.tokens.contains(member.token),
               arrivals.contains(where: { $0.contains(member.token) })
            {
                members.append(member)
            }
        }
        return members
    }

    private func existingAwayTile(
        with id: DwindleTileId,
        arrivals: borrowing [DwindleHistoryArrival]
    ) -> DwindleTile? {
        for index in arrivals.indices {
            if let tile = arrivals[index].existingTile(with: id) { return tile }
        }
        return nil
    }

    private func survivingAwayTile(
        _ saved: DwindleLayoutSnapshot.Node,
        away: borrowing DwindleLayoutAway,
        state: DwindleWorkspaceState
    ) -> DwindleTile? {
        for index in saved.members {
            let token = away.snapshot.members[index].token
            if !away.tokens.contains(token), let tile = state.leafByToken[token]?.tile, tile.id == saved.tileId {
                return tile
            }
        }
        for leaf in state.leafByToken.values {
            if let tile = leaf.tile, tile.id == saved.tileId { return tile }
        }
        return nil
    }

    private func restoreAwayMembers(
        _ returning: consuming [DwindleTileMember],
        to tile: DwindleTile,
        saved: DwindleLayoutSnapshot.Node,
        snapshot: borrowing DwindleLayoutSnapshot
    ) {
        var members = tile.members
        members.reserveCapacity(members.count + returning.count)
        for member in returning {
            guard !members.contains(where: { $0.token == member.token }),
                  let savedIndex = saved.members.first(where: { snapshot.members[$0].token == member.token })
            else { continue }
            var next: Int?
            for index in (savedIndex + 1) ..< saved.members.upperBound {
                if let position = members.firstIndex(where: { $0.token == snapshot.members[index].token }) {
                    next = position
                    break
                }
            }
            if let next {
                members.insert(member, at: next)
            } else {
                var previous: Int?
                for index in (saved.members.lowerBound ..< savedIndex).reversed() {
                    if let position = members.firstIndex(where: { $0.token == snapshot.members[index].token }) {
                        previous = position
                        break
                    }
                }
                members.insert(member, at: previous.map { $0 + 1 } ?? members.count)
            }
        }
        tile.restoreMembers(members, activeToken: tile.activeToken)
    }

    private func installAwayTile(
        _ tile: DwindleTile,
        savedIndex: Int,
        away: borrowing DwindleLayoutAway,
        state: DwindleWorkspaceState
    ) {
        if state.root.tile == nil, state.root.children.isEmpty {
            state.root.kind = .leaf(tile: tile)
            state.root.edgeExpansion = nil
            state.root.cachedContentFrame = nil
            state.root.clearAnimations()
            for member in tile.members { state.leafByToken[member.token] = state.root }
            return
        }
        let saved = away.snapshot.nodes[savedIndex]
        let id = findNodeById(saved.id, in: state.root) == nil ? saved.id : UUID()
        let leaf = DwindleNode(kind: .leaf(tile: tile), id: id)
        if !insertAwayLeaf(leaf, savedIndex: savedIndex, ancestorIndex: 0, away: away, state: state) {
            wrapAwayAnchor(
                state.root, with: leaf, state: state,
                split: DwindleHistorySplit(orientation: .horizontal, ratio: 1, returningFirst: false)
            )
        }
        for member in tile.members { state.leafByToken[member.token] = leaf }
    }

    private func insertAwayLeaf(
        _ leaf: DwindleNode,
        savedIndex: Int,
        ancestorIndex: Int,
        away: borrowing DwindleLayoutAway,
        state: DwindleWorkspaceState
    ) -> Bool {
        let saved = away.snapshot.nodes[ancestorIndex]
        guard let orientation = saved.orientation,
              let first = saved.firstChild, let second = saved.secondChild
        else { return false }
        let returningFirst = savedIndex < second
        let branch = returningFirst ? first : second
        if branch != savedIndex,
           insertAwayLeaf(leaf, savedIndex: savedIndex, ancestorIndex: branch, away: away, state: state)
        {
            return true
        }
        let sibling = returningFirst ? second : first
        var anchor = currentAwayAnchor(at: sibling, away: away, state: state)
        if anchor == nil {
            anchor = currentAwayAnchor(at: sibling, away: away, state: state, includingReturning: true)
        }
        guard let anchor else { return false }
        wrapAwayAnchor(
            anchor, with: leaf, state: state,
            split: DwindleHistorySplit(orientation: orientation, ratio: saved.ratio, returningFirst: returningFirst)
        )
        return true
    }

    private func currentAwayAnchor(
        at index: Int,
        away: borrowing DwindleLayoutAway,
        state: DwindleWorkspaceState,
        includingReturning: Bool = false
    ) -> DwindleNode? {
        let saved = away.snapshot.nodes[index]
        if let first = saved.firstChild, let second = saved.secondChild {
            let left = currentAwayAnchor(at: first, away: away, state: state, includingReturning: includingReturning)
            let right = currentAwayAnchor(at: second, away: away, state: state, includingReturning: includingReturning)
            return commonAwayAncestor(left, right)
        }
        var anchor: DwindleNode?
        for index in saved.members {
            let token = away.snapshot.members[index].token
            let returning = away.tokens.contains(token)
            if includingReturning || !returning, let leaf = state.leafByToken[token] {
                anchor = commonAwayAncestor(anchor, leaf)
            }
        }
        return anchor
    }

    private func commonAwayAncestor(_ first: DwindleNode?, _ second: DwindleNode?) -> DwindleNode? {
        guard let first else { return second }
        guard let second else { return first }
        var candidate: DwindleNode? = first
        while let current = candidate {
            var descendant: DwindleNode? = second
            while let node = descendant {
                if node === current { return current }
                descendant = node.parent
            }
            candidate = current.parent
        }
        return nil
    }

    private func wrapAwayAnchor(
        _ anchor: DwindleNode,
        with leaf: DwindleNode,
        state: DwindleWorkspaceState,
        split: DwindleHistorySplit
    ) {
        if let parent = anchor.parent, let index = parent.children.firstIndex(where: { $0 === anchor }) {
            let branch = DwindleNode(kind: .split(orientation: split.orientation, ratio: split.ratio))
            parent.children[index] = branch
            branch.parent = parent
            branch.replaceChildren(
                first: split.returningFirst ? leaf : anchor,
                second: split.returningFirst ? anchor : leaf
            )
        } else {
            let remainder = DwindleNode(kind: anchor.kind)
            swap(&remainder.children, &anchor.children)
            for child in remainder.children { child.parent = remainder }
            remainder.edgeExpansion = anchor.edgeExpansion
            if let tile = remainder.tile {
                for member in tile.members { state.leafByToken[member.token] = remainder }
            }
            anchor.kind = .split(orientation: split.orientation, ratio: split.ratio)
            anchor.edgeExpansion = nil
            anchor.cachedContentFrame = nil
            anchor.clearAnimations()
            anchor.replaceChildren(
                first: split.returningFirst ? leaf : remainder,
                second: split.returningFirst ? remainder : leaf
            )
        }
    }
}
