// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct DwindleInteractiveResize {
    struct Axis {
        let orientation: DwindleOrientation
        let splitId: DwindleNodeId
        let childId: DwindleNodeId
        let originRatio: CGFloat?
        let length: CGFloat
    }

    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    var edges: ResizeEdge
    let startMouseLocation: CGPoint
    let innerGap: CGFloat

    var horizontal: Axis?
    var vertical: Axis?

    var didChange = false
}

enum DwindleResizeEdgePolicy {
    case exact
    case nearestMovable
}

extension DwindleLayoutEngine {
    func interactiveResizeBegin(
        token: WindowToken,
        edges: ResizeEdge,
        startLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        innerGap: CGFloat,
        edgePolicy: DwindleResizeEdgePolicy = .exact
    ) -> Bool {
        guard interactiveResize == nil else { return false }
        guard let leaf = findNode(for: token, in: workspaceId), leaf.isLeaf, !leaf.isFullscreen else { return false }

        let horizontal = resolveControllingSplit(
            from: leaf,
            edges: edges,
            axis: .horizontal,
            policy: edgePolicy,
            workspaceId: workspaceId
        )
        let vertical = resolveControllingSplit(
            from: leaf,
            edges: edges,
            axis: .vertical,
            policy: edgePolicy,
            workspaceId: workspaceId
        )
        guard horizontal != nil || vertical != nil else { return false }

        interactiveResize = DwindleInteractiveResize(
            token: token,
            workspaceId: workspaceId,
            edges: edgePolicy == .exact ? edges : [horizontal?.edge ?? [], vertical?.edge ?? []],
            startMouseLocation: startLocation,
            innerGap: innerGap,
            horizontal: horizontal?.axis,
            vertical: vertical?.axis
        )
        return true
    }

    func interactiveResizeUpdate(currentLocation: CGPoint, edges: ResizeEdge? = nil) -> Bool {
        guard var resize = interactiveResize else { return false }
        guard let leaf = findNode(for: resize.token, in: resize.workspaceId), leaf.isLeaf else {
            clearInteractiveResize()
            return false
        }

        if let edges {
            resize.horizontal = resize.horizontal ?? resolveControllingSplit(
                from: leaf, edges: edges, axis: .horizontal, policy: .exact, workspaceId: resize.workspaceId
            )?.axis
            resize.vertical = resize.vertical ?? resolveControllingSplit(
                from: leaf, edges: edges, axis: .vertical, policy: .exact, workspaceId: resize.workspaceId
            )?.axis
            resize.edges.formUnion(edges)
            interactiveResize = resize
        }

        var changed = false
        if applyAxis(
            resize: resize,
            leaf: leaf,
            axis: resize.horizontal,
            delta: currentLocation.x - resize.startMouseLocation.x
        ) {
            changed = true
        }
        if applyAxis(
            resize: resize,
            leaf: leaf,
            axis: resize.vertical,
            delta: currentLocation.y - resize.startMouseLocation.y
        ) {
            changed = true
        }

        if changed {
            interactiveResize?.didChange = true
        }
        return changed
    }

    @discardableResult
    func interactiveResizeEnd() -> Bool {
        let didChange = interactiveResize?.didChange ?? false
        interactiveResize = nil
        return didChange
    }

    func clearInteractiveResize() {
        interactiveResize = nil
    }

    func cancelAnimations(in workspaceId: WorkspaceDescriptor.ID) {
        guard let root = root(for: workspaceId) else { return }
        clearAnimationsRecursive(root)
    }

    private func clearAnimationsRecursive(_ node: DwindleNode) {
        node.clearAnimations()
        for child in node.children {
            clearAnimationsRecursive(child)
        }
    }

    private func applyAxis(
        resize: DwindleInteractiveResize,
        leaf: DwindleNode,
        axis: DwindleInteractiveResize.Axis?,
        delta: CGFloat
    ) -> Bool {
        guard let axis, let originRatio = axis.originRatio,
              let match = controllingSplit(
                  from: leaf,
                  orientation: axis.orientation,
                  wantFirstChild: resize.edges.contains(axis.orientation == .horizontal ? .right : .top),
                  workspaceId: resize.workspaceId
              ),
              match.split.id == axis.splitId,
              match.child.id == axis.childId
        else {
            return false
        }

        let newRatio = clampedRatioRespectingMinimums(
            originRatio + 2 * delta / axis.length,
            for: match.split,
            innerGap: resize.innerGap,
            excludedTokens: excludedTokens(in: resize.workspaceId)
        )
        guard newRatio != match.split.splitRatio else { return false }
        match.split.kind = .split(orientation: axis.orientation, ratio: newRatio)
        return true
    }

    private func resolveControllingSplit(
        from leaf: DwindleNode,
        edges: ResizeEdge,
        axis: DwindleOrientation,
        policy: DwindleResizeEdgePolicy,
        workspaceId: WorkspaceDescriptor.ID
    ) -> (axis: DwindleInteractiveResize.Axis, edge: ResizeEdge)? {
        let (firstEdge, secondEdge): (ResizeEdge, ResizeEdge) = switch axis {
        case .horizontal: (.right, .left)
        case .vertical: (.top, .bottom)
        }
        let preferred: ResizeEdge
        if edges.contains(firstEdge) {
            preferred = firstEdge
        } else if edges.contains(secondEdge) {
            preferred = secondEdge
        } else {
            return nil
        }
        if let resolved = resolveAxis(
            from: leaf,
            axis: axis,
            wantFirstChild: preferred == firstEdge,
            workspaceId: workspaceId
        ) {
            return (resolved, preferred)
        }
        guard policy == .nearestMovable,
              let resolved = resolveAxis(
                  from: leaf,
                  axis: axis,
                  wantFirstChild: preferred != firstEdge,
                  workspaceId: workspaceId
              )
        else { return nil }
        return (resolved, preferred == firstEdge ? secondEdge : firstEdge)
    }

    private func resolveAxis(
        from leaf: DwindleNode,
        axis: DwindleOrientation,
        wantFirstChild: Bool,
        workspaceId: WorkspaceDescriptor.ID
    ) -> DwindleInteractiveResize.Axis? {
        guard let match = controllingSplit(
                  from: leaf,
                  orientation: axis,
                  wantFirstChild: wantFirstChild,
                  workspaceId: workspaceId
              ),
              let frame = match.split.cachedFrame
        else {
            return nil
        }
        let axisLength = axis == .horizontal ? frame.width : frame.height
        guard axisLength.isFinite, axisLength > 0 else { return nil }
        return DwindleInteractiveResize.Axis(
            orientation: axis,
            splitId: match.split.id,
            childId: match.child.id,
            originRatio: match.split.splitRatio,
            length: axisLength
        )
    }

    private func controllingSplit(
        from leaf: DwindleNode,
        orientation: DwindleOrientation,
        wantFirstChild: Bool,
        workspaceId: WorkspaceDescriptor.ID
    ) -> (split: DwindleNode, child: DwindleNode)? {
        var child = leaf
        var current = leaf.parent
        while let parent = current {
            if case let .split(splitOrientation, _) = parent.kind,
               splitOrientation == orientation,
               splitHasTwoVisibleBranches(
                   parent,
                   excluding: excludedTokens(in: workspaceId)
               ),
               child.isFirstChild(of: parent) == wantFirstChild
            {
                return (parent, child)
            }
            child = parent
            current = parent.parent
        }
        return nil
    }
}
