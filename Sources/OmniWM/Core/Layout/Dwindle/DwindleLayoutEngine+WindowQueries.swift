// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    func containsWindow(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        existingState(for: workspaceId)?.leafByToken[token] != nil
    }

    func findNode(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> DwindleNode? {
        existingState(for: workspaceId)?.leafByToken[token]
    }

    func isWindowFullscreen(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        existingState(for: workspaceId)?.isWindowFullscreen(token) == true
    }

    func fullscreenTokens(in workspaceId: WorkspaceDescriptor.ID) -> Set<WindowToken> {
        guard let state = existingState(for: workspaceId) else { return [] }
        return Set(state.leafByToken.keys.filter { token in
            state.leafByToken[token]?.tile?.member(for: token)?.isFullscreen == true
        })
    }

    func windowCount(in workspaceId: WorkspaceDescriptor.ID) -> Int {
        existingState(for: workspaceId)?.leafByToken.count ?? 0
    }

    func setExcludedTokens(
        _ excludedTokens: Set<WindowToken>,
        authoritativeTokens: Set<WindowToken>? = nil,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard isMutationSanctioned else {
            assertionFailure("Dwindle projection exclusions changed outside a sanctioned WorldStore scope")
            return
        }
        let currentTokens = existingState(for: workspaceId)?.excludedTokens ?? []
        let resolvedTokens: Set<WindowToken>
        if let authoritativeTokens {
            resolvedTokens = excludedTokens.union(currentTokens.subtracting(authoritativeTokens))
        } else {
            resolvedTokens = excludedTokens
        }
        let state = ensureState(for: workspaceId)
        state.excludedTokens = resolvedTokens
        reconcileProjectedSelection(in: state)
    }

    func excludedTokens(in workspaceId: WorkspaceDescriptor.ID) -> Set<WindowToken> {
        existingState(for: workspaceId)?.excludedTokens ?? []
    }

    func tileCount(in workspaceId: WorkspaceDescriptor.ID) -> Int {
        existingState(for: workspaceId)?.tileCount ?? 0
    }

    func inactiveGroupTokens(in workspaceId: WorkspaceDescriptor.ID) -> Set<WindowToken> {
        guard let state = existingState(for: workspaceId) else { return [] }
        var tokens: Set<WindowToken> = []
        tokens.reserveCapacity(max(0, state.leafByToken.count - state.tileCount))
        for (token, leaf) in state.leafByToken {
            if let tile = leaf.tile,
               tile.isGrouped,
               visibleMember(in: tile, excluding: state.excludedTokens)?.token != token
            {
                tokens.insert(token)
            }
        }
        return tokens
    }

    func isInactiveGroupMember(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let state = existingState(for: workspaceId),
              let tile = state.leafByToken[token]?.tile,
              tile.isGrouped
        else {
            return false
        }
        return visibleMember(in: tile, excluding: state.excludedTokens)?.token != token
    }

    func tileSnapshot(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> DwindleTileSnapshot? {
        guard let leaf = findNode(for: token, in: workspaceId), let tile = leaf.tile else { return nil }
        return tileSnapshot(tile: tile, leaf: leaf)
    }

    func groupedTileSnapshots(in workspaceId: WorkspaceDescriptor.ID) -> [DwindleTileSnapshot] {
        guard let state = existingState(for: workspaceId) else { return [] }
        var snapshots: [DwindleTileSnapshot] = []
        collectGroupedTileSnapshots(
            node: state.root,
            excludedTokens: state.excludedTokens,
            into: &snapshots
        )
        return snapshots
    }

    func forEachGroupedTileGeometry(
        in workspaceId: WorkspaceDescriptor.ID,
        _ body: (DwindleGroupedTileGeometry) -> Void
    ) {
        guard let state = existingState(for: workspaceId) else { return }
        visitGroupedTileGeometry(
            node: state.root,
            excludedTokens: state.excludedTokens,
            body
        )
    }

    func tileFrame(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> CGRect? {
        findNode(for: token, in: workspaceId)?.cachedFrame
    }

    func contentFrame(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> CGRect? {
        findNode(for: token, in: workspaceId)?.cachedContentFrame
    }

    private func tileSnapshot(tile: DwindleTile, leaf: DwindleNode) -> DwindleTileSnapshot {
        DwindleTileSnapshot(
            id: tile.id,
            members: tile.members,
            activeIndex: tile.activeIndex,
            tileFrame: leaf.cachedFrame,
            contentFrame: leaf.cachedContentFrame
        )
    }

    private func collectGroupedTileSnapshots(
        node: DwindleNode,
        excludedTokens: Set<WindowToken>,
        into snapshots: inout [DwindleTileSnapshot]
    ) {
        if let tile = node.tile {
            let members = tile.members.filter { !excludedTokens.contains($0.token) }
            guard members.count > 1,
                  let member = visibleMember(in: tile, excluding: excludedTokens),
                  let activeIndex = members.firstIndex(where: { $0.token == member.token })
            else {
                return
            }
            snapshots.append(
                DwindleTileSnapshot(
                    id: tile.id,
                    members: members,
                    activeIndex: activeIndex,
                    tileFrame: node.cachedFrame,
                    contentFrame: node.cachedContentFrame
                )
            )
            return
        }
        for child in node.children {
            collectGroupedTileSnapshots(
                node: child,
                excludedTokens: excludedTokens,
                into: &snapshots
            )
        }
    }

    private func visitGroupedTileGeometry(
        node: DwindleNode,
        excludedTokens: Set<WindowToken>,
        _ body: (DwindleGroupedTileGeometry) -> Void
    ) {
        if let tile = node.tile {
            var visibleMemberCount = 0
            for member in tile.members where !excludedTokens.contains(member.token) {
                visibleMemberCount += 1
                if visibleMemberCount > 1 {
                    break
                }
            }
            guard visibleMemberCount > 1,
                  let activeMember = visibleMember(in: tile, excluding: excludedTokens)
            else {
                return
            }
            body(
                DwindleGroupedTileGeometry(
                    id: tile.id,
                    activeToken: activeMember.token,
                    tileFrame: node.cachedFrame,
                    contentFrame: node.cachedContentFrame
                )
            )
            return
        }
        for child in node.children {
            visitGroupedTileGeometry(
                node: child,
                excludedTokens: excludedTokens,
                body
            )
        }
    }

    func selectedNode(in workspaceId: WorkspaceDescriptor.ID) -> DwindleNode? {
        guard let state = existingState(for: workspaceId), let nodeId = state.selectedNodeId else { return nil }
        return findNodeById(nodeId, in: state.root)
    }

    func setSelectedNode(_ node: DwindleNode?, in workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let node else {
            ensureState(for: workspaceId).selectedNodeId = nil
            return
        }
        guard let state = existingState(for: workspaceId), findNodeById(node.id, in: state.root) != nil else { return }
        state.selectedNodeId = node.id
    }

    @discardableResult
    func setPreselection(_ direction: Direction?, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        let state = ensureState(for: workspaceId)
        guard state.preselection != direction else { return false }
        state.preselection = direction
        return true
    }

    func findNodeById(_ nodeId: DwindleNodeId, in root: DwindleNode) -> DwindleNode? {
        if root.id == nodeId { return root }
        for child in root.children {
            if let found = findNodeById(nodeId, in: child) {
                return found
            }
        }
        return nil
    }
}

extension DwindleWorkspaceState {
    func isWindowFullscreen(_ token: WindowToken) -> Bool {
        guard let node = leafByToken[token], case let .leaf(tile?) = node.kind else { return false }
        return tile.member(for: token)?.isFullscreen == true
    }
}
