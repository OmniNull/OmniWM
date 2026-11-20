// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct DwindleLayoutSnapshot {
    struct Node {
        let id: DwindleNodeId
        let orientation: DwindleOrientation?
        var ratio: CGFloat
        var firstChild: Int?
        var secondChild: Int?
        let tileId: DwindleTileId?
        let members: Range<Int>
        let active: WindowToken?
        let expansion: DwindleEdgeExpansion?

        func restoreSplit(to node: DwindleNode) {
            guard let orientation else { return }
            if node.splitRatio != ratio { node.kind = .split(orientation: orientation, ratio: ratio) }
            if !hasSameExpansion(as: node.edgeExpansion) { node.edgeExpansion = expansion }
        }

        private func hasSameExpansion(as current: DwindleEdgeExpansion?) -> Bool {
            switch (expansion, current) {
            case (nil, nil):
                true
            case let (saved?, existing?):
                saved.leafId == existing.leafId && saved.childId == existing.childId
                    && saved.edge == existing.edge && saved.originalRatio == existing.originalRatio
                    && saved.expandedRatio == existing.expandedRatio
            default:
                false
            }
        }
    }

    var nodes: [Node] = []
    var members: [DwindleTileMember] = []
    let selected: WindowToken?
    let focused: WindowToken?
    let preselection: Direction?

    mutating func capture(_ node: DwindleNode) {
        let index = nodes.count
        let memberStart = members.count
        let tile = node.tile
        if let tile { members.append(contentsOf: tile.members) }
        nodes.append(Node(
            id: node.id, orientation: node.splitOrientation, ratio: node.splitRatio ?? 1,
            tileId: tile?.id, members: memberStart ..< members.count,
            active: tile?.activeToken, expansion: node.edgeExpansion
        ))
        if let first = node.firstChild() {
            nodes[index].firstChild = nodes.count
            capture(first)
        }
        if let second = node.secondChild() {
            nodes[index].secondChild = nodes.count
            capture(second)
        }
    }

    func matches(_ node: DwindleNode, at index: Int = 0) -> Bool {
        guard nodes.indices.contains(index) else { return false }
        let saved = nodes[index]
        guard saved.orientation == node.splitOrientation else { return false }
        if saved.orientation != nil {
            guard saved.ratio == node.splitRatio,
                  let first = saved.firstChild, let second = saved.secondChild,
                  let currentFirst = node.firstChild(), let currentSecond = node.secondChild()
            else { return false }
            return matches(currentFirst, at: first) && matches(currentSecond, at: second)
        }
        return matchesMembers(node.tile, saved: saved)
    }

    func canRestoreInPlace(_ node: DwindleNode, at index: Int = 0) -> Bool {
        guard nodes.indices.contains(index) else { return false }
        let saved = nodes[index]
        guard saved.id == node.id, saved.orientation == node.splitOrientation else { return false }
        if saved.orientation != nil {
            guard node.children.count == 2,
                  let first = saved.firstChild, let second = saved.secondChild,
                  let currentFirst = node.firstChild(), let currentSecond = node.secondChild()
            else { return false }
            return canRestoreInPlace(currentFirst, at: first) && canRestoreInPlace(currentSecond, at: second)
        }
        return node.children.isEmpty && saved.tileId == node.tile?.id
            && matchesMembers(node.tile, saved: saved, includingState: false)
    }

    func restoreInPlace(_ node: DwindleNode, at index: Int = 0) {
        let saved = nodes[index]
        saved.restoreSplit(to: node)
        if let tile = node.tile {
            tile.restoreMemberStates(from: members, range: saved.members, activeToken: saved.active)
        }
        if let first = saved.firstChild, let currentFirst = node.firstChild() {
            restoreInPlace(currentFirst, at: first)
        }
        if let second = saved.secondChild, let currentSecond = node.secondChild() {
            restoreInPlace(currentSecond, at: second)
        }
    }

    private func matchesMembers(_ tile: DwindleTile?, saved: Node, includingState: Bool = true) -> Bool {
        guard let tile else { return saved.members.isEmpty }
        guard tile.members.count == saved.members.count,
              !includingState || tile.activeToken == saved.active
        else { return false }
        for (offset, member) in tile.members.enumerated() {
            let expected = members[saved.members.lowerBound + offset]
            if includingState ? member != expected : member.token != expected.token { return false }
        }
        return true
    }
}

extension DwindleLayoutEngine {
    func layoutSnapshot(
        in workspaceId: WorkspaceDescriptor.ID,
        focused: WindowToken? = nil
    ) -> DwindleLayoutSnapshot? {
        assertSanctionedMutation()
        let state = ensureState(for: workspaceId)
        let selected = selectedNode(in: workspaceId)?.windowToken
        var snapshot = DwindleLayoutSnapshot(
            selected: selected, focused: focused ?? selected, preselection: state.preselection
        )
        snapshot.nodes.reserveCapacity(max(1, state.tileCount * 2 - 1))
        snapshot.members.reserveCapacity(state.leafByToken.count)
        snapshot.capture(state.root)
        return snapshot
    }
}
