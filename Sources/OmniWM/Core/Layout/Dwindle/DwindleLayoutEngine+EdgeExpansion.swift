// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct DwindleEdgeExpansion {
    let leafId: DwindleNodeId
    let childId: DwindleNodeId
    let edge: ResizeEdge
    let originalRatio: CGFloat
    let expandedRatio: CGFloat
}

extension DwindleLayoutEngine {
    @discardableResult
    func toggleEdgeExpansion(
        for token: WindowToken,
        edge: ResizeEdge,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        let orientation: DwindleOrientation
        switch edge {
        case .left,
             .right: orientation = .horizontal
        case .bottom,
             .top: orientation = .vertical
        default: return false
        }
        let excluded = excludedTokens(in: workspaceId)
        guard let leaf = findNode(for: token, in: workspaceId), leaf.isLeaf, !leaf.isFullscreen,
              !excluded.contains(token),
              let match = controllingSplit(
                  from: leaf, orientation: orientation, wantFirstChild: edge == .right || edge == .top,
                  workspaceId: workspaceId
              ),
              let frame = match.split.cachedFrame,
              (orientation == .horizontal ? frame.width : frame.height) > 0,
              let range = feasibleRatioRange(
                  for: match.split, innerGap: settings.innerGap, excludedTokens: excluded, bounds: 0 ... 2
              )
        else { return false }
        return applyEdgeExpansion(to: match, leafId: leaf.id, edge: edge, range: range)
    }

    private func applyEdgeExpansion(
        to match: borrowing DwindleResizeMatch,
        leafId: DwindleNodeId,
        edge: ResizeEdge,
        range: ClosedRange<CGFloat>
    ) -> Bool {
        guard case let .split(orientation, ratio) = match.split.kind else { return false }
        if let saved = match.split.edgeExpansion,
           saved.leafId == leafId, saved.childId == match.child.id, saved.edge == edge,
           saved.expandedRatio == ratio
        {
            match.split.edgeExpansion = nil
            let restoredRatio = min(max(saved.originalRatio, range.lowerBound), range.upperBound)
            guard restoredRatio != ratio else { return false }
            match.split.kind = .split(orientation: orientation, ratio: restoredRatio)
            return true
        }
        let towardTrailingEdge = edge == .right || edge == .top
        let expandedRatio = towardTrailingEdge ? range.upperBound : range.lowerBound
        guard towardTrailingEdge ? expandedRatio > ratio : expandedRatio < ratio else {
            match.split.edgeExpansion = nil
            return false
        }
        match.split.edgeExpansion = DwindleEdgeExpansion(
            leafId: leafId, childId: match.child.id, edge: edge,
            originalRatio: ratio, expandedRatio: expandedRatio
        )
        match.split.kind = .split(orientation: orientation, ratio: expandedRatio)
        return true
    }
}
