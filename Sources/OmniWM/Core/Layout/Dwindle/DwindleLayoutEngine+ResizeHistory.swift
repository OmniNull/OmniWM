// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

private struct DwindleResizeHistoryOrigins {
    private var bindings: InlineArray<6, DwindleInteractiveResize.Axis?>
    private var changed: UInt8 = 0

    init(_ resize: borrowing DwindleInteractiveResize) {
        let horizontal = resize.edges.contains([.left, .right]) ? resize.centered?.horizontal : nil
        let vertical = resize.edges.contains([.bottom, .top]) ? resize.centered?.vertical : nil
        bindings = [
            horizontal?.lower, horizontal?.upper, vertical?.lower, vertical?.upper,
            resize.horizontal, resize.vertical
        ]
        for index in bindings.indices {
            guard let axis = bindings[index] else { continue }
            for earlier in 0 ..< index where bindings[earlier]?.splitId == axis.splitId {
                bindings[index] = nil
                break
            }
        }
    }

    mutating func hasChanges(from leaf: DwindleNode) -> Bool {
        var childId = leaf.id
        var ancestor = leaf.parent
        while let node = ancestor {
            for index in bindings.indices {
                guard let axis = bindings[index], axis.splitId == node.id,
                      axis.childId == childId, axis.orientation == node.splitOrientation,
                      let original = axis.originRatio, node.splitRatio != original
                else { continue }
                changed |= 1 << index
            }
            childId = node.id
            ancestor = node.parent
        }
        return changed != 0
    }

    func restoreOriginalRatios(in snapshot: inout DwindleLayoutSnapshot) {
        for nodeIndex in snapshot.nodes.indices {
            for index in bindings.indices where changed & (1 << index) != 0 {
                guard let axis = bindings[index], axis.splitId == snapshot.nodes[nodeIndex].id,
                      let original = axis.originRatio
                else { continue }
                snapshot.nodes[nodeIndex].ratio = original
                break
            }
        }
    }
}

extension DwindleLayoutEngine {
    func recordNativeResizeHistory(_ resize: borrowing DwindleInteractiveResize) {
        guard let leaf = findNode(for: resize.token, in: resize.workspaceId), leaf.isLeaf else { return }
        var origins = DwindleResizeHistoryOrigins(resize)
        guard origins.hasChanges(from: leaf),
              var snapshot = layoutSnapshot(in: resize.workspaceId)
        else { return }
        origins.restoreOriginalRatios(in: &snapshot)
        recordLayoutChange(in: resize.workspaceId, since: consume snapshot)
    }
}
