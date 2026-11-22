// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    private struct SplitMoveGeometry {
        let frame: CGRect?
        let hasPeer: Bool
        var target: DwindleMoveTarget?
        var targetRegion: CGRect?
    }

    func canInsertAtSplitBoundary(
        token: WindowToken,
        splitId: DwindleNodeId,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard canInsertAtWorkspaceEdge(token: token, in: workspaceId),
              let state = existingState(for: workspaceId),
              let source = state.leafByToken[token],
              let split = findNodeById(splitId, in: state.root),
              split.children.count == 2
        else { return false }
        for branch in split.children {
            let status = insertionPeerStatus(in: branch, source: source, excluding: state.excludedTokens)
            if !status.hasPeer { return false }
        }
        return true
    }

    @discardableResult
    func insertLeafTile(
        of token: WindowToken,
        betweenChildrenOf splitId: DwindleNodeId,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard canInsertAtSplitBoundary(token: token, splitId: splitId, in: workspaceId),
              let state = existingState(for: workspaceId),
              let source = state.leafByToken[token],
              let split = findNodeById(splitId, in: state.root),
              let orientation = split.splitOrientation,
              let first = split.firstChild(), let second = split.secondChild(),
              let destination = source.sibling() === split ? source.parent : split
        else { return false }

        if let sibling = source.sibling(), let tile = sibling.tile,
           let frame = sibling.presentedFrame(at: animationClock?.now() ?? CACurrentMediaTime())
        {
            for member in tile.members where state.pendingMovementFrameSeeds[member.token] == nil {
                state.pendingMovementFrameSeeds[member.token] = frame
            }
        }
        cleanupAfterRemoval(source, state: state)

        insertLeaf(source, between: first, and: second, orientation: orientation, in: destination)
        state.selectedNodeId = source.id
        return true
    }

    func canAttachTransfer(atSplitBoundary splitId: DwindleNodeId, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let state = existingState(for: workspaceId),
              !visibleTiles(in: workspaceId).fullscreen,
              let split = findNodeById(splitId, in: state.root)
        else { return false }
        return splitHasTwoVisibleBranches(split, excluding: state.excludedTokens)
    }

    func insertLeaf(
        _ leaf: DwindleNode,
        between first: DwindleNode,
        and second: DwindleNode,
        orientation: DwindleOrientation,
        in destination: DwindleNode
    ) {
        let inserted = DwindleNode(kind: .split(orientation: orientation, ratio: 1))
        destination.replaceChildren(first: first, second: inserted)
        inserted.replaceChildren(first: leaf, second: second)
    }

    func splitBoundaryMoveTarget(
        at point: CGPoint,
        for token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        time: TimeInterval
    ) -> DwindleMoveTarget? {
        splitBoundaryMoveHit(at: point, for: token, in: workspaceId, time: time)?.target
    }

    func splitBoundaryMoveHit(
        at point: CGPoint,
        for token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        time: TimeInterval
    ) -> (target: DwindleMoveTarget, region: CGRect)? {
        guard let state = existingState(for: workspaceId), state.tileCount > 2,
              let source = state.leafByToken[token]
        else { return nil }
        let geometry = splitMoveGeometry(
            at: point, in: state.root, source: source, excludedTokens: state.excludedTokens, time: time
        )
        guard let target = geometry.target, let region = geometry.targetRegion,
              canInsertAtWorkspaceEdge(token: token, in: workspaceId)
        else { return nil }
        return (target, region)
    }

    func transferSplitBoundaryTarget(
        at point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        time: TimeInterval
    ) -> DwindleMoveTarget? {
        guard let state = existingState(for: workspaceId) else { return nil }
        return splitMoveGeometry(
            at: point, in: state.root, source: nil, excludedTokens: state.excludedTokens, time: time
        ).target
    }

    private func splitMoveGeometry(
        at point: CGPoint,
        in node: DwindleNode,
        source: DwindleNode?,
        excludedTokens: Set<WindowToken>,
        time: TimeInterval
    ) -> SplitMoveGeometry {
        if visibleMember(in: node.tile, excluding: excludedTokens) != nil {
            return SplitMoveGeometry(
                frame: presentedTileFrame(of: node, at: time), hasPeer: node !== source, target: nil
            )
        }
        guard let orientation = node.splitOrientation,
              let first = node.firstChild(), let second = node.secondChild()
        else { return SplitMoveGeometry(frame: nil, hasPeer: false, target: nil) }
        let firstGeometry = splitMoveGeometry(
            at: point,
            in: first,
            source: source,
            excludedTokens: excludedTokens,
            time: time
        )
        let secondGeometry = splitMoveGeometry(
            at: point,
            in: second,
            source: source,
            excludedTokens: excludedTokens,
            time: time
        )
        var frame = firstGeometry.frame
        if let next = secondGeometry.frame { frame = frame?.union(next) ?? next }
        var result = SplitMoveGeometry(
            frame: frame,
            hasPeer: firstGeometry.hasPeer || secondGeometry.hasPeer,
            target: firstGeometry.target ?? secondGeometry.target,
            targetRegion: firstGeometry.targetRegion ?? secondGeometry.targetRegion
        )
        guard result.target == nil, firstGeometry.hasPeer, secondGeometry.hasPeer,
              let firstFrame = firstGeometry.frame, let secondFrame = secondGeometry.frame
        else { return result }
        let horizontal = orientation == .horizontal
        let band = splitBoundaryBand(between: firstFrame, and: secondFrame, horizontal: horizontal)
        if band.width > 0, band.height > 0, band.contains(point) {
            result.target = .splitBoundary(
                node.id, frame: WindowMoveGeometry.targetFrame(in: secondFrame, direction: horizontal ? .left : .down)
            )
            result.targetRegion = band
        }
        return result
    }

    private func presentedTileFrame(of node: DwindleNode, at time: TimeInterval) -> CGRect? {
        guard let presented = node.presentedFrame(at: time) else { return nil }
        guard let tileFrame = node.cachedFrame, let contentFrame = node.cachedContentFrame else { return presented }
        return CGRect(
            x: presented.minX - (contentFrame.minX - tileFrame.minX),
            y: presented.minY - (contentFrame.minY - tileFrame.minY),
            width: presented.width + tileFrame.width - contentFrame.width,
            height: presented.height + tileFrame.height - contentFrame.height
        )
    }

    private func splitBoundaryBand(between firstFrame: CGRect, and secondFrame: CGRect, horizontal: Bool) -> CGRect {
        let boundary = horizontal
            ? (firstFrame.maxX + secondFrame.minX) / 2
            : (firstFrame.maxY + secondFrame.minY) / 2
        let tolerance = min(12, (horizontal
                ? min(firstFrame.width, secondFrame.width)
                : min(firstFrame.height, secondFrame.height)) / 10)
        return horizontal
            ? CGRect(
                x: boundary - tolerance,
                y: max(firstFrame.minY, secondFrame.minY),
                width: tolerance * 2,
                height: min(firstFrame.maxY, secondFrame.maxY) - max(firstFrame.minY, secondFrame.minY)
            )
            : CGRect(
                x: max(firstFrame.minX, secondFrame.minX),
                y: boundary - tolerance,
                width: min(firstFrame.maxX, secondFrame.maxX) - max(firstFrame.minX, secondFrame.minX),
                height: tolerance * 2
            )
    }
}
