// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func liveColumnStrip(
        context: NiriInteractionContext,
        state: ViewportState
    ) -> [LiveColumnMove.StripColumn] {
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let geometry = projectedGeometrySnapshot(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        guard let anchor = projectedViewportAnchor(state: state, geometry: geometry, in: context.workspaceId)
        else { return [] }
        let viewPosition = anchor.primaryPosition + state.viewOffset
        return geometry.columns.map { column in
            let minX = context.workingFrame.minX + column.primaryPosition - viewPosition
            let span = projectedPrimarySpan(
                for: column.projectedColumn,
                workingFrame: context.workingFrame,
                gap: context.gaps,
                orientation: context.orientation
            )
            return LiveColumnMove.StripColumn(column: column.projectedColumn.column, minX: minX, maxX: minX + span)
        }
    }

    func liveColumn(
        in strip: [LiveColumnMove.StripColumn],
        at cursor: CGPoint,
        ignoring dropSpace: NiriContainer?
    ) -> NiriContainer? {
        strip.first { $0.column !== dropSpace && $0.contains(x: cursor.x) }?.column
    }

    func liveTargetSide(
        _ target: NiriContainer,
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        awayFromHome: Bool,
        context: NiriInteractionContext
    ) -> LiveColumnMove.Side {
        guard let placed = strip.first(where: { $0.column === target }) else { return .after }
        if awayFromHome, let ahead = liveColumnMove?.edgeScrollSide {
            return ahead
        }
        let visibleMinX = max(placed.minX, context.workingFrame.minX)
        let visibleMaxX = min(placed.maxX, context.workingFrame.maxX)
        let middle = visibleMaxX > visibleMinX ? (visibleMinX + visibleMaxX) / 2 : placed.midX
        return cursor.x < middle ? .before : .after
    }

    func liveDraggedColumn(for move: LiveColumnMove) -> NiriContainer? {
        guard findNode(by: move.windowId, in: move.workspaceId) is NiriWindow else { return nil }
        return liveColumn(withId: move.homeColumnId, in: move.workspaceId)
    }

    func liveColumn(withId id: NodeId, in workspaceId: WorkspaceDescriptor.ID) -> NiriContainer? {
        findNode(by: id, in: workspaceId) as? NiriContainer
    }

    func removeLivePlaceholder(_ columnId: NodeId, in workspaceId: WorkspaceDescriptor.ID) {
        guard let column = liveColumn(withId: columnId, in: workspaceId),
              column.windowNodes.isEmpty,
              column.isLiveDropSpace || column.isLiveHomeSpot
        else { return }
        column.remove()
    }

    func liveEdgeScrollLimit(
        towardTrailingEdge: Bool,
        context: NiriInteractionContext,
        state: ViewportState
    ) -> CGFloat? {
        let limits = liveEdgeScrollLimits(
            strip: liveColumnStrip(context: context, state: state),
            context: context,
            state: state
        )
        return towardTrailingEdge ? limits.trailing : limits.leading
    }

    func liveEdgeScrollLimits(
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext,
        state: ViewportState
    ) -> (leading: CGFloat?, trailing: CGFloat?) {
        guard isLiveColumnMoveActive(in: context.workspaceId),
              let range = liveStripScrollRange(strip: strip, context: context)
        else { return (nil, nil) }
        let pixel = 1.0 / displayScale(in: context.workspaceId)
        func limit(_ shift: CGFloat) -> CGFloat? {
            abs(shift) >= pixel ? state.viewOffset + shift : nil
        }
        return (limit(range.lowerBound), limit(range.upperBound))
    }

    func animateLiveColumnChange(
        from before: [NodeId: CGFloat],
        anchoredOn anchor: NiriContainer,
        animatingAnchorFrom anchorStart: CGFloat? = nil,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let after = rebaseLiveView(from: before, anchoredOn: anchor, context: context, state: &state)
        for column in columns(in: context.workspaceId) {
            let start = column === anchor ? anchorStart ?? before[column.id] : before[column.id]
            guard let previous = start, let current = after[column.id] else { continue }
            let displacement = previous - current
            guard abs(displacement) > 0.001 else { continue }
            animateReorderedColumn(column, displacement: displacement, context: context)
        }
    }

    @discardableResult
    func rebaseLiveView(
        from before: [NodeId: CGFloat],
        anchoredOn anchor: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> [NodeId: CGFloat] {
        if let index = columnIndex(of: anchor, in: context.workspaceId) {
            state.activeColumnIndex = index
        }
        let after = primaryPositions(context: context, state: state)
        if let previous = before[anchor.id], let current = after[anchor.id] {
            state.rebaseOffset(by: previous - current)
        }
        return after
    }

    func retargetActiveColumn(
        to column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        guard let index = columnIndex(of: column, in: context.workspaceId) else { return }
        let columns = columns(in: context.workspaceId)
        let positions = primaryPositions(context: context, state: state)
        if columns.indices.contains(state.activeColumnIndex),
           let previous = positions[columns[state.activeColumnIndex].id],
           let current = positions[column.id]
        {
            state.rebaseOffset(by: previous - current)
        }
        state.activeColumnIndex = index
    }

    func liveEdgeRevealShift(
        showing column: NiriContainer,
        checking edges: [LiveColumnMove.Side],
        slack: CGFloat,
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> CGFloat {
        guard let placed = strip.first(where: { $0.column === column }),
              let range = liveStripScrollRange(strip: strip, context: context)
        else { return 0 }
        for edge in edges {
            switch edge {
            case .before:
                let overshoot = placed.minX - (context.workingFrame.minX + context.gaps)
                if overshoot < -slack {
                    return overshoot.clamped(to: range)
                }
            case .after:
                let overshoot = placed.maxX - (context.workingFrame.maxX - context.gaps)
                if overshoot > slack {
                    return overshoot.clamped(to: range)
                }
            }
        }
        return 0
    }

    func liveStripScrollRange(
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> ClosedRange<CGFloat>? {
        guard let drift = stripEndsDrift(strip: strip, context: context) else { return nil }
        return min(0, drift.lowest) ... max(0, drift.highest)
    }

    func keptStripEndsDrift(
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> (lowest: CGFloat, highest: CGFloat)? {
        guard let first = strip.first, let last = strip.last,
              ViewportState.stripEndOffsets(
                  stripSpan: last.maxX - first.minX,
                  viewSpan: context.workingFrame.width,
                  gap: context.gaps
              ) != nil
        else { return nil }
        return stripEndsDrift(strip: strip, context: context)
    }

    func stripEndsDrift(
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> (lowest: CGFloat, highest: CGFloat)? {
        guard let first = strip.first, let last = strip.last else { return nil }
        return (
            first.minX - (context.workingFrame.minX + context.gaps),
            last.maxX - (context.workingFrame.maxX - context.gaps)
        )
    }
}
