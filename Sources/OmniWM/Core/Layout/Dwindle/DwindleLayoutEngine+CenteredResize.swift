// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension DwindleInteractiveResize {
    struct Centered {
        let horizontal: CenteredAxis?
        let vertical: CenteredAxis?
    }

    struct CenteredAxis {
        let lower: Axis
        let upper: Axis
        let outerIsLower: Bool
        let outerChildLength: CGFloat
        let innerChildLength: CGFloat
    }
}

private struct DwindleResizeChange {
    let splitId: DwindleNodeId
    let orientation: DwindleOrientation
    let ratio: CGFloat
}

private struct DwindleResizePair {
    let outer: DwindleResizeChange
    let inner: DwindleResizeChange
}

private struct DwindleResizeAffine {
    let origin: CGFloat
    let slope: CGFloat

    func value(at displacement: CGFloat) -> CGFloat {
        origin + slope * displacement
    }

    func scaled(by scale: CGFloat) -> Self {
        Self(origin: origin * scale, slope: slope * scale)
    }

    func subtracting(_ other: Self) -> Self {
        Self(origin: origin - other.origin, slope: slope - other.slope)
    }
}

private struct DwindleResizeProjection {
    let outerChildId: DwindleNodeId
    let extent: DwindleResizeAffine
    let orientation: DwindleOrientation
    let innerGap: CGFloat
}

private struct DwindleResizeBoundary {
    let splitId: DwindleNodeId
    let originalRatio: CGFloat
    let first: Bool
    let minimums: (child: CGFloat, sibling: CGFloat)
    let fractions: (minimum: CGFloat, maximum: CGFloat)

    func change(fraction: CGFloat, displacement: CGFloat, orientation: DwindleOrientation) -> DwindleResizeChange {
        DwindleResizeChange(
            splitId: splitId, orientation: orientation,
            ratio: displacement == 0 ? originalRatio : 2 * (first ? fraction : 1 - fraction)
        )
    }
}

private struct DwindleResizeGeometry {
    let outer: DwindleResizeBoundary
    let inner: DwindleResizeBoundary
    let outerLength: CGFloat
    let targetSpan: DwindleResizeAffine
    let projection: DwindleResizeProjection

    func constrainOuter(_ segment: inout DwindleResizeSegment) {
        segment.requireNonnegative(projection.extent.subtracting(.init(origin: outer.minimums.child, slope: 0)))
        segment.requireNonnegative(DwindleResizeAffine(
            origin: outerLength - outer.minimums.sibling, slope: 0
        ).subtracting(projection.extent))
        segment.requireNonnegative(projection.extent.subtracting(.init(
            origin: outerLength * outer.fractions.minimum, slope: 0
        )))
        segment.requireNonnegative(DwindleResizeAffine(
            origin: outerLength * outer.fractions.maximum, slope: 0
        ).subtracting(projection.extent))
    }
}

private struct DwindleResizeSegment {
    let displacement: CGFloat
    let direction: CGFloat
    var breakpoint: CGFloat
    var limit: CGFloat

    mutating func requireNonnegative(_ value: DwindleResizeAffine) {
        if value.value(at: displacement) < 0 {
            limit = displacement
        } else if value.slope * direction < 0 {
            let boundary = -value.origin / value.slope
            if direction * (boundary - displacement) <= 0 {
                limit = displacement
            } else if direction * (boundary - limit) < 0 {
                limit = boundary
            }
        }
    }

    mutating func constrain(
        _ child: DwindleResizeAffine,
        within parent: DwindleResizeAffine,
        minimums: (child: CGFloat, sibling: CGFloat),
        fractions: (minimum: CGFloat, maximum: CGFloat)
    ) {
        requireNonnegative(child.subtracting(.init(origin: minimums.child, slope: 0)))
        requireNonnegative(parent.subtracting(child).subtracting(.init(origin: minimums.sibling, slope: 0)))
        requireNonnegative(child.subtracting(parent.scaled(by: fractions.minimum)))
        requireNonnegative(parent.scaled(by: fractions.maximum).subtracting(child))
    }

    mutating func minimum(_ first: DwindleResizeAffine, _ second: DwindleResizeAffine) -> DwindleResizeAffine {
        select(first, second, minimum: true)
    }

    mutating func maximum(_ first: DwindleResizeAffine, _ second: DwindleResizeAffine) -> DwindleResizeAffine {
        select(first, second, minimum: false)
    }

    private mutating func select(
        _ first: DwindleResizeAffine,
        _ second: DwindleResizeAffine,
        minimum: Bool
    ) -> DwindleResizeAffine {
        let difference = first.subtracting(second)
        let firstIsSmaller: Bool
        if difference.slope == 0 {
            firstIsSmaller = difference.origin < 0
        } else {
            let crossing = -difference.origin / difference.slope
            if crossing.isFinite,
               direction * (crossing - displacement) > 0,
               direction * (crossing - breakpoint) < 0
            {
                breakpoint = crossing
            }
            firstIsSmaller = displacement == crossing
                ? difference.slope * direction < 0
                : difference.slope * (displacement - crossing) < 0
        }
        return firstIsSmaller == minimum ? first : second
    }
}

extension DwindleLayoutEngine {
    func centeredResizeBindings(
        from leaf: DwindleNode,
        workspaceId: WorkspaceDescriptor.ID,
        innerGap: CGFloat
    ) -> DwindleInteractiveResize.Centered {
        DwindleInteractiveResize.Centered(
            horizontal: centeredResizeAxis(
                from: leaf,
                orientation: .horizontal,
                workspaceId: workspaceId,
                innerGap: innerGap
            ),
            vertical: centeredResizeAxis(
                from: leaf,
                orientation: .vertical,
                workspaceId: workspaceId,
                innerGap: innerGap
            )
        )
    }

    private func centeredResizeAxis(
        from leaf: DwindleNode,
        orientation: DwindleOrientation,
        workspaceId: WorkspaceDescriptor.ID,
        innerGap: CGFloat
    ) -> DwindleInteractiveResize.CenteredAxis? {
        guard let lowerMatch = controllingSplit(
                  from: leaf,
                  orientation: orientation,
                  wantFirstChild: false,
                  workspaceId: workspaceId
              ),
              let lower = resizeAxis(from: lowerMatch, orientation: orientation),
              let upperMatch = controllingSplit(
                  from: leaf,
                  orientation: orientation,
                  wantFirstChild: true,
                  workspaceId: workspaceId
              ),
              let upper = resizeAxis(from: upperMatch, orientation: orientation)
        else { return nil }
        var outerIsLower = true
        var ancestor = lowerMatch.split.parent
        while let node = ancestor {
            if node.id == upper.splitId {
                outerIsLower = false
                break
            }
            ancestor = node.parent
        }
        let outer: DwindleResizeMatch
        let inner: DwindleResizeMatch
        if outerIsLower {
            outer = consume lowerMatch
            inner = consume upperMatch
        } else {
            outer = consume upperMatch
            inner = consume lowerMatch
        }
        let excluded = excludedTokens(in: workspaceId)
        guard let outerLength = centeredChildLength(
                  of: outer.child, in: outer.split, innerGap: innerGap, excludedTokens: excluded
              ),
              let innerLength = centeredChildLength(
                  of: inner.child, in: inner.split, innerGap: innerGap, excludedTokens: excluded
              )
        else { return nil }
        return DwindleInteractiveResize.CenteredAxis(
            lower: lower, upper: upper, outerIsLower: outerIsLower,
            outerChildLength: outerLength, innerChildLength: innerLength
        )
    }

    private func centeredChildLength(
        of child: DwindleNode,
        in split: DwindleNode,
        innerGap: CGFloat,
        excludedTokens: borrowing Set<WindowToken>
    ) -> CGFloat? {
        guard case let .split(orientation, ratio) = split.kind,
              let rect = split.cachedFrame,
              let minimums = centeredMinimums(for: split, innerGap: innerGap, excludedTokens: excludedTokens)
        else { return nil }
        let frames = splitRect(rect, orientation: orientation, ratio: ratio, minimums: minimums)
        let childFrame = child.isFirstChild(of: split) ? frames.0 : frames.1
        return orientation == .horizontal ? childFrame.width : childFrame.height
    }

    private func centeredMinimums(
        for split: DwindleNode,
        innerGap: CGFloat,
        excludedTokens: borrowing Set<WindowToken>
    ) -> (first: CGSize, second: CGSize)? {
        guard let orientation = split.splitOrientation,
              let first = split.firstChild(), let second = split.secondChild()
        else { return nil }
        let boundaries = splitChildBoundaryEdges(
            tilingBoundaryEdges(of: split, excluding: excludedTokens), orientation: orientation
        )
        return (
            computeProjectedMinSizeForSubtree(
                first, boundaryEdges: boundaries.first, excludedTokens: excludedTokens, innerGap: innerGap
            ),
            computeProjectedMinSizeForSubtree(
                second, boundaryEdges: boundaries.second, excludedTokens: excludedTokens, innerGap: innerGap
            )
        )
    }

    func updateCenteredResize(
        _ resize: borrowing DwindleInteractiveResize,
        leaf: DwindleNode,
        currentLocation: CGPoint
    ) -> Bool {
        guard let centered = resize.centered else { return false }
        let horizontalPaired = resize.edges.contains([.left, .right])
        let verticalPaired = resize.edges.contains([.bottom, .top])
        let dx = currentLocation.x - resize.startMouseLocation.x
        let dy = currentLocation.y - resize.startMouseLocation.y
        let horizontal = horizontalPaired
            ? centeredResizePlan(centered.horizontal, resize: resize, leaf: leaf, displacement: -dx) : nil
        let vertical = verticalPaired
            ? centeredResizePlan(centered.vertical, resize: resize, leaf: leaf, displacement: -dy) : nil
        let horizontalSingle = horizontalPaired ? nil
            : centeredSingleResizePlan(resize.horizontal, resize: resize, leaf: leaf, delta: dx)
        let verticalSingle = verticalPaired ? nil
            : centeredSingleResizePlan(resize.vertical, resize: resize, leaf: leaf, delta: dy)
        var changed = false
        var ancestor = leaf.parent
        while let node = ancestor {
            let change: DwindleResizeChange?
            if node.id == horizontal?.outer.splitId { change = horizontal?.outer }
            else if node.id == horizontal?.inner.splitId { change = horizontal?.inner }
            else if node.id == vertical?.outer.splitId { change = vertical?.outer }
            else if node.id == vertical?.inner.splitId { change = vertical?.inner }
            else if node.id == horizontalSingle?.splitId { change = horizontalSingle }
            else if node.id == verticalSingle?.splitId { change = verticalSingle }
            else { change = nil }
            if let change, node.splitRatio != change.ratio {
                node.kind = .split(orientation: change.orientation, ratio: change.ratio)
                changed = true
            }
            ancestor = node.parent
        }
        return changed
    }

    private func centeredSingleResizePlan(
        _ axis: DwindleInteractiveResize.Axis?,
        resize: borrowing DwindleInteractiveResize,
        leaf: DwindleNode,
        delta: CGFloat
    ) -> DwindleResizeChange? {
        guard let axis, let ratio = axis.originRatio,
              let match = controllingSplit(
                  from: leaf, orientation: axis.orientation,
                  wantFirstChild: resize.edges.contains(axis.orientation == .horizontal ? .right : .top),
                  workspaceId: resize.workspaceId
              ), match.split.id == axis.splitId, match.child.id == axis.childId
        else { return nil }
        return DwindleResizeChange(
            splitId: axis.splitId, orientation: axis.orientation,
            ratio: clampedRatioRespectingMinimums(
                ratio + 2 * delta / axis.length, for: match.split, innerGap: resize.innerGap,
                excludedTokens: excludedTokens(in: resize.workspaceId), referenceRatio: ratio
            )
        )
    }

    private func centeredResizePlan(
        _ axis: DwindleInteractiveResize.CenteredAxis?,
        resize: borrowing DwindleInteractiveResize,
        leaf: DwindleNode,
        displacement requested: CGFloat
    ) -> DwindleResizePair? {
        guard let axis, requested.isFinite,
              let lower = controllingSplit(
                  from: leaf, orientation: axis.lower.orientation, wantFirstChild: false,
                  workspaceId: resize.workspaceId
              ), lower.split.id == axis.lower.splitId, lower.child.id == axis.lower.childId,
              let upper = controllingSplit(
                  from: leaf, orientation: axis.upper.orientation, wantFirstChild: true, workspaceId: resize.workspaceId
              ), upper.split.id == axis.upper.splitId, upper.child.id == axis.upper.childId,
              let lowerRatio = axis.lower.originRatio, let upperRatio = axis.upper.originRatio
        else { return nil }
        let outer: DwindleResizeMatch
        let inner: DwindleResizeMatch
        if axis.outerIsLower {
            outer = consume lower
            inner = consume upper
        } else {
            outer = consume upper
            inner = consume lower
        }
        let outerAxis = axis.outerIsLower ? axis.lower : axis.upper
        let outerRatio = axis.outerIsLower ? lowerRatio : upperRatio
        let innerRatio = axis.outerIsLower ? upperRatio : lowerRatio
        let orientation = outerAxis.orientation
        if requested == 0 {
            return DwindleResizePair(
                outer: DwindleResizeChange(splitId: outer.split.id, orientation: orientation, ratio: outerRatio),
                inner: DwindleResizeChange(splitId: inner.split.id, orientation: orientation, ratio: innerRatio)
            )
        }
        let excluded = excludedTokens(in: resize.workspaceId)
        guard let geometry = centeredResizeGeometry(
            axis, outer: outer, inner: inner, innerGap: resize.innerGap, excludedTokens: excluded
        ) else { return nil }
        return solveCenteredResize(geometry, inner: inner.split, requested: requested, excludedTokens: excluded)
    }

    private func centeredResizeBoundary(
        _ match: borrowing DwindleResizeMatch,
        ratio: CGFloat,
        projection: DwindleResizeProjection,
        excludedTokens: borrowing Set<WindowToken>
    ) -> DwindleResizeBoundary? {
        guard let minimums = centeredMinimums(
            for: match.split, innerGap: projection.innerGap, excludedTokens: excludedTokens
        ) else { return nil }
        let first = match.child.isFirstChild(of: match.split)
        let horizontal = projection.orientation == .horizontal
        let childMinimum = horizontal
            ? (first ? minimums.first.width : minimums.second.width)
            : (first ? minimums.first.height : minimums.second.height)
        let siblingMinimum = horizontal
            ? (first ? minimums.second.width : minimums.first.width)
            : (first ? minimums.second.height : minimums.first.height)
        let range = settings.resizeRatioRange(from: first ? ratio : 2 - ratio)
        return DwindleResizeBoundary(
            splitId: match.split.id, originalRatio: ratio, first: first,
            minimums: (childMinimum, siblingMinimum),
            fractions: (settings.ratioToFraction(range.lowerBound), settings.ratioToFraction(range.upperBound))
        )
    }

    private func centeredResizeGeometry(
        _ axis: DwindleInteractiveResize.CenteredAxis,
        outer: borrowing DwindleResizeMatch,
        inner: borrowing DwindleResizeMatch,
        innerGap: CGFloat,
        excludedTokens: borrowing Set<WindowToken>
    ) -> DwindleResizeGeometry? {
        let outerAxis = axis.outerIsLower ? axis.lower : axis.upper
        let innerAxis = axis.outerIsLower ? axis.upper : axis.lower
        let projection = DwindleResizeProjection(
            outerChildId: outer.child.id,
            extent: DwindleResizeAffine(origin: axis.outerChildLength, slope: 1),
            orientation: outerAxis.orientation, innerGap: innerGap
        )
        guard let outerRatio = outerAxis.originRatio, let innerRatio = innerAxis.originRatio,
              let outerBoundary = centeredResizeBoundary(
                  outer, ratio: outerRatio, projection: projection, excludedTokens: excludedTokens
              ),
              let innerBoundary = centeredResizeBoundary(
                  inner, ratio: innerRatio, projection: projection, excludedTokens: excludedTokens
              )
        else { return nil }
        return DwindleResizeGeometry(
            outer: outerBoundary, inner: innerBoundary, outerLength: outerAxis.length,
            targetSpan: DwindleResizeAffine(origin: axis.innerChildLength, slope: 2),
            projection: projection
        )
    }

    private func solveCenteredResize(
        _ geometry: DwindleResizeGeometry,
        inner: DwindleNode,
        requested: CGFloat,
        excludedTokens: borrowing Set<WindowToken>
    ) -> DwindleResizePair? {
        let direction: CGFloat = requested > 0 ? 1 : -1
        var position: CGFloat = 0
        while true {
            var segment = DwindleResizeSegment(
                displacement: position, direction: direction, breakpoint: requested, limit: requested
            )
            geometry.constrainOuter(&segment)
            guard let innerSpan = centeredProjectedExtent(
                of: inner, projection: geometry.projection, excludedTokens: excludedTokens, segment: &segment
            ) else { return nil }
            segment.constrain(
                geometry.targetSpan, within: innerSpan,
                minimums: geometry.inner.minimums, fractions: geometry.inner.fractions
            )
            let blocked = direction * (segment.limit - segment.breakpoint) < 0 || segment.limit == position
            let next = blocked ? segment.limit : segment.breakpoint
            if blocked || next == requested {
                return DwindleResizePair(
                    outer: geometry.outer.change(
                        fraction: geometry.projection.extent.value(at: next) / geometry.outerLength,
                        displacement: next, orientation: geometry.projection.orientation
                    ),
                    inner: geometry.inner.change(
                        fraction: geometry.targetSpan.value(at: next) / innerSpan.value(at: next),
                        displacement: next, orientation: geometry.projection.orientation
                    )
                )
            }
            position = next
        }
    }

    private func centeredProjectedExtent(
        of node: DwindleNode,
        projection: DwindleResizeProjection,
        excludedTokens: borrowing Set<WindowToken>,
        segment: inout DwindleResizeSegment
    ) -> DwindleResizeAffine? {
        if node.id == projection.outerChildId { return projection.extent }
        guard let parent = node.parent,
              let parentExtent = centeredProjectedExtent(
                  of: parent, projection: projection, excludedTokens: excludedTokens, segment: &segment
              )
        else { return nil }
        guard case let .split(parentOrientation, ratio) = parent.kind,
              parentOrientation == projection.orientation,
              splitHasTwoVisibleBranches(parent, excluding: excludedTokens)
        else { return parentExtent }
        guard let minimums = centeredMinimums(
            for: parent, innerGap: projection.innerGap, excludedTokens: excludedTokens
        )
        else { return nil }
        let first = node.isFirstChild(of: parent)
        let horizontal = projection.orientation == .horizontal
        let childMinimum = horizontal
            ? (first ? minimums.first.width : minimums.second.width)
            : (first ? minimums.first.height : minimums.second.height)
        let siblingMinimum = horizontal
            ? (first ? minimums.second.width : minimums.first.width)
            : (first ? minimums.second.height : minimums.first.height)
        segment.requireNonnegative(parentExtent.subtracting(.init(origin: childMinimum + siblingMinimum, slope: 0)))
        let fraction = settings.ratioToFraction(ratio)
        let proportional = parentExtent.scaled(by: first ? fraction : 1 - fraction)
        let belowSibling = parentExtent.subtracting(.init(origin: siblingMinimum, slope: 0))
        let upper = segment.minimum(proportional, belowSibling)
        return segment.maximum(.init(origin: childMinimum, slope: 0), upper)
    }
}
