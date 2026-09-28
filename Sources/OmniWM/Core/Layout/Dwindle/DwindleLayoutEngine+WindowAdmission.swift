// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    @discardableResult
    func addWindow(
        token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID,
        activeWindowFrame: CGRect?,
        joinsSelectedTile: Bool = false
    ) -> DwindleNode {
        let state = ensureState(for: workspaceId)

        if let existing = state.leafByToken[token] {
            _ = existing.tile?.activate(token)
            state.selectedNodeId = existing.id
            return existing
        }

        if case let .leaf(tile) = state.root.kind, tile == nil {
            state.root.kind = .leaf(tile: DwindleTile(token: token))
            state.leafByToken[token] = state.root
            state.tileCount = 1
            state.selectedNodeId = state.root.id
            return state.root
        }

        let targetNode: DwindleNode
        if let selected = selectedNode(in: workspaceId), selected.isLeaf {
            targetNode = selected
        } else {
            targetNode = state.root.descendToFirstLeaf()
        }

        if joinsSelectedTile,
           settings.stackIncomingWindows,
           state.preselection == nil,
           let targetTile = targetNode.tile
        {
            targetTile.insertAfterActive(DwindleTileMember(token: token, isFullscreen: false))
            state.leafByToken[token] = targetNode
            state.selectedNodeId = targetNode.id
            return targetNode
        }

        let newLeaf = splitLeaf(
            targetNode,
            newWindow: token,
            state: state,
            activeWindowFrame: activeWindowFrame,
            preselectedDirection: state.preselection
        )
        state.preselection = nil

        state.leafByToken[token] = newLeaf
        state.selectedNodeId = newLeaf.id
        return newLeaf
    }

    func splitLeaf(
        _ leaf: DwindleNode,
        newWindow: WindowToken,
        state: DwindleWorkspaceState,
        activeWindowFrame: CGRect?,
        preselectedDirection: Direction? = nil
    ) -> DwindleNode {
        guard case let .leaf(existingTile) = leaf.kind else {
            let newLeaf = DwindleNode(kind: .leaf(tile: DwindleTile(token: newWindow)))
            leaf.appendChild(newLeaf)
            state.tileCount += 1
            return newLeaf
        }

        return splitLeaf(
            leaf,
            tiles: (new: DwindleTile(token: newWindow), existing: existingTile),
            state: state,
            activeWindowFrame: activeWindowFrame,
            preselectedDirection: preselectedDirection
        )
    }

    func splitLeaf(
        _ leaf: DwindleNode,
        tiles: (new: DwindleTile, existing: DwindleTile?),
        state: DwindleWorkspaceState,
        activeWindowFrame: CGRect?,
        preselectedDirection: Direction?
    ) -> DwindleNode {
        let targetRect = leaf.cachedFrame
        let (orientation, newFirst): (DwindleOrientation, Bool)
        if let dir = preselectedDirection {
            orientation = dir.dwindleOrientation
            newFirst = dir == .left || dir == .down
        } else {
            (orientation, newFirst) = planSplit(
                targetRect: targetRect,
                activeWindowFrame: activeWindowFrame
            )
        }

        let existingLeaf = DwindleNode(kind: .leaf(tile: tiles.existing))
        let newLeaf = DwindleNode(kind: .leaf(tile: tiles.new))

        leaf.kind = .split(orientation: orientation, ratio: settings.defaultSplitRatio)
        leaf.cachedContentFrame = nil
        leaf.clearAnimations()
        state.tileCount += 1

        if newFirst {
            leaf.replaceChildren(first: newLeaf, second: existingLeaf)
        } else {
            leaf.replaceChildren(first: existingLeaf, second: newLeaf)
        }

        if let existingTile = tiles.existing {
            for member in existingTile.members {
                state.leafByToken[member.token] = existingLeaf
            }
        }

        return newLeaf
    }

    private func planSplit(
        targetRect: CGRect?,
        activeWindowFrame: CGRect?
    ) -> (orientation: DwindleOrientation, newFirst: Bool) {
        guard settings.smartSplit,
              let targetRect,
              let activeFrame = activeWindowFrame
        else {
            return (aspectOrientation(for: targetRect), false)
        }

        let targetCenter = targetRect.center
        let activeCenter = activeFrame.center

        let deltaX = activeCenter.x - targetCenter.x
        let deltaY = activeCenter.y - targetCenter.y

        let slope: CGFloat
        if abs(deltaX) < 0.001 {
            slope = .infinity
        } else {
            slope = deltaY / deltaX
        }

        let aspect: CGFloat
        if abs(targetRect.width) < 0.001 {
            aspect = .infinity
        } else {
            aspect = targetRect.height / targetRect.width
        }

        if abs(slope) < aspect {
            return (.horizontal, deltaX < 0)
        } else {
            return (.vertical, deltaY < 0)
        }
    }

    private func aspectOrientation(for rect: CGRect?) -> DwindleOrientation {
        guard let rect else { return .horizontal }
        if rect.height * settings.splitWidthMultiplier > rect.width {
            return .vertical
        }
        return .horizontal
    }
}
