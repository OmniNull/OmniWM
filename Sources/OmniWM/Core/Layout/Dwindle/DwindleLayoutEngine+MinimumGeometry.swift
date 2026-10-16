// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    func computeProjectedMinSizeForSubtree(
        _ node: DwindleNode,
        boundaryEdges: ResizeEdge,
        excludedTokens: Set<WindowToken>,
        innerGap: CGFloat? = nil
    ) -> CGSize {
        let effectiveInnerGap = innerGap ?? settings.innerGap
        switch node.kind {
        case let .leaf(tile):
            guard let tile,
                  visibleMember(in: tile, excluding: excludedTokens) != nil
            else {
                return CGSize(width: 1, height: 1)
            }
            return projectedMinimumSize(
                for: tile,
                boundaryEdges: boundaryEdges,
                excludedTokens: excludedTokens,
                innerGap: effectiveInnerGap
            )

        case let .split(orientation, _):
            guard let first = node.firstChild(), let second = node.secondChild() else {
                return CGSize(width: 1, height: 1)
            }
            let firstVisible = subtreeHasVisibleMember(first, excluding: excludedTokens)
            let secondVisible = subtreeHasVisibleMember(second, excluding: excludedTokens)
            if firstVisible != secondVisible {
                return computeProjectedMinSizeForSubtree(
                    firstVisible ? first : second,
                    boundaryEdges: boundaryEdges,
                    excludedTokens: excludedTokens,
                    innerGap: effectiveInnerGap
                )
            }
            guard firstVisible, secondVisible else {
                return CGSize(width: 1, height: 1)
            }

            let childEdges = splitChildBoundaryEdges(boundaryEdges, orientation: orientation)
            let firstMin = computeProjectedMinSizeForSubtree(
                first,
                boundaryEdges: childEdges.first,
                excludedTokens: excludedTokens,
                innerGap: effectiveInnerGap
            )
            let secondMin = computeProjectedMinSizeForSubtree(
                second,
                boundaryEdges: childEdges.second,
                excludedTokens: excludedTokens,
                innerGap: effectiveInnerGap
            )
            return combinedMinimumSize(firstMin, secondMin, orientation: orientation)
        }
    }

    private func combinedMinimumSize(
        _ firstMin: CGSize,
        _ secondMin: CGSize,
        orientation: DwindleOrientation
    ) -> CGSize {
        switch orientation {
        case .horizontal:
            return CGSize(
                width: firstMin.width + secondMin.width,
                height: max(firstMin.height, secondMin.height)
            )
        case .vertical:
            return CGSize(
                width: max(firstMin.width, secondMin.width),
                height: firstMin.height + secondMin.height
            )
        }
    }

    func splitChildBoundaryEdges(
        _ boundaryEdges: ResizeEdge,
        orientation: DwindleOrientation
    ) -> (first: ResizeEdge, second: ResizeEdge) {
        switch orientation {
        case .horizontal:
            (boundaryEdges.subtracting(.right), boundaryEdges.subtracting(.left))
        case .vertical:
            (boundaryEdges.subtracting(.top), boundaryEdges.subtracting(.bottom))
        }
    }

    func minimumSize(
        for tile: DwindleTile,
        excluding excludedTokens: Set<WindowToken>
    ) -> CGSize {
        var result = CGSize(width: 1, height: 1)
        var visibleCount = 0
        for member in tile.members where !excludedTokens.contains(member.token) {
            visibleCount += 1
            let minimum = constraints(for: member.token).minSize
            result.width = max(result.width, minimum.width)
            result.height = max(result.height, minimum.height)
        }
        if visibleCount > 1 {
            result.width += tabRailWidth
        }
        return result
    }

    func projectedMinimumSize(
        for tile: DwindleTile,
        boundaryEdges: ResizeEdge,
        excludedTokens: Set<WindowToken>,
        innerGap: CGFloat
    ) -> CGSize {
        var minSize = minimumSize(for: tile, excluding: excludedTokens)
        let inset = innerGap / 2
        if !boundaryEdges.contains(.left) { minSize.width += inset }
        if !boundaryEdges.contains(.right) { minSize.width += inset }
        if !boundaryEdges.contains(.top) { minSize.height += inset }
        if !boundaryEdges.contains(.bottom) { minSize.height += inset }
        return minSize
    }

    func tilingBoundaryEdges(of node: DwindleNode, excluding excludedTokens: Set<WindowToken>) -> ResizeEdge {
        var edges = ResizeEdge.all
        var child = node
        while let parent = child.parent {
            if case let .split(orientation, _) = parent.kind,
               splitHasTwoVisibleBranches(parent, excluding: excludedTokens)
            {
                switch orientation {
                case .horizontal:
                    edges.subtract(child.isFirstChild(of: parent) ? .right : .left)
                case .vertical:
                    edges.subtract(child.isFirstChild(of: parent) ? .top : .bottom)
                }
            }
            child = parent
        }
        return edges
    }
}
