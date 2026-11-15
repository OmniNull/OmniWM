// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct ColumnStretch: Equatable {
    let span: CGFloat
    let keptSideShift: CGFloat
}

private struct StretchedStrip {
    let placed: ClosedRange<CGFloat>
    let start: CGFloat
    let end: CGFloat
    let towardTrailingEdge: Bool

    var lead: CGFloat {
        placed.lowerBound - start
    }

    var rest: CGFloat {
        end - start - (placed.upperBound - placed.lowerBound)
    }

    func keptStart(span: CGFloat) -> CGFloat {
        towardTrailingEdge ? start : placed.upperBound - span - lead
    }

    func reachesWhenPlaced(at target: CGFloat, context: NiriInteractionContext) -> (CGFloat, CGFloat) {
        if towardTrailingEdge {
            return (
                target - (context.primaryOrigin + context.gaps) - lead,
                2 * (target - context.primaryOrigin - lead) - (context.primarySpan - rest)
            )
        }
        return (
            context.primaryEnd - context.gaps - rest + lead - target,
            context.primarySpan - rest - 2 * (target - context.primaryOrigin - lead)
        )
    }
}

extension NiriLayoutEngine {
    func columnScreenSpan(
        _ column: NiriContainer,
        context: NiriInteractionContext,
        state: ViewportState
    ) -> ClosedRange<CGFloat>? {
        liveColumnStrip(context: context, state: state)
            .first { $0.column === column }
            .map { $0.minX ... $0.maxX }
    }

    func columnStretchToScreenEdge(
        _ column: NiriContainer,
        towardTrailingEdge: Bool,
        context: NiriInteractionContext,
        state: ViewportState
    ) -> ColumnStretch? {
        let strip = liveColumnStrip(context: context, state: state)
        guard let placed = strip.first(where: { $0.column === column }),
              let first = strip.first,
              let last = strip.last
        else { return nil }
        let stretched = StretchedStrip(
            placed: placed.minX ... placed.maxX,
            start: first.minX,
            end: last.maxX,
            towardTrailingEdge: towardTrailingEdge
        )
        let limits = edgePeekBounds(of: column, context: context)
        let target = towardTrailingEdge ? limits.upperBound : limits.lowerBound
        let keptReach = towardTrailingEdge ? target - placed.minX : placed.maxX - target
        let horizontal = context.orientation == .horizontal
        let bounds = horizontal
            ? projectedWidthBounds(for: column, workspaceId: context.workspaceId)
            : projectedHeightBounds(for: column, workspaceId: context.workspaceId)
        let widest = min(context.primarySpan - 2 * context.gaps, bounds.max ?? .infinity)
        let reaches = stretched.reachesWhenPlaced(at: target, context: context)
        let candidates: InlineArray<3, CGFloat> = [keptReach, reaches.0, reaches.1]
        var requested = max(bounds.min, min(candidates[0], widest))
        var distance = abs(farEdge(of: stretched, span: requested, context: context) - target)
        for index in 1 ..< candidates.count {
            let candidate = max(bounds.min, min(candidates[index], widest))
            let candidateDistance = abs(farEdge(of: stretched, span: candidate, context: context) - target)
            if candidateDistance < distance - 0.5 {
                requested = candidate
                distance = candidateDistance
            }
        }
        let span = column.resolvedPrimarySpan(
            .fixed(requested),
            orientation: context.orientation,
            availableSpace: context.primarySpan,
            gaps: context.gaps,
            contentInset: horizontal ? tabContentInset(for: column) : 0
        )
        let settled = settledSpan(of: stretched, span: span, context: context)
        let moved = towardTrailingEdge ? placed.minX - settled.lowerBound : settled.upperBound - placed.maxX
        let overshoot = abs(moved) < 0.5 ? max(0, span - max(requested, keptReach)) : 0
        return ColumnStretch(span: span, keptSideShift: moved + overshoot)
    }

    private func farEdge(of stretched: StretchedStrip, span: CGFloat, context: NiriInteractionContext) -> CGFloat {
        let placed = settledSpan(of: stretched, span: span, context: context)
        return stretched.towardTrailingEdge ? placed.upperBound : placed.lowerBound
    }

    private func settledSpan(
        of stretched: StretchedStrip,
        span: CGFloat,
        context: NiriInteractionContext
    ) -> ClosedRange<CGFloat> {
        let stripSpan = stretched.rest + span
        var start = stretched.keptStart(span: span)
        if centresFittingStrip(in: context.workspaceId),
           let offset = ViewportState.centredStripOffset(
               stripSpan: stripSpan,
               viewSpan: context.primarySpan,
               gap: context.gaps,
               scale: displayScale(in: context.workspaceId)
           )
        {
            start = context.primaryOrigin - offset
        } else if !centresFocusedColumn(in: context.workspaceId),
                  ViewportState
                      .stripEndOffsets(stripSpan: stripSpan, viewSpan: context.primarySpan, gap: context.gaps) != nil
        {
            start = min(max(start, context.primaryEnd - context.gaps - stripSpan), context.primaryOrigin + context.gaps)
        }
        let minX = start + stretched.lead
        return minX ... minX + span
    }

    func stretchColumn(
        _ column: NiriContainer,
        to stretch: ColumnStretch,
        towardTrailingEdge: Bool,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        assertSanctionedMutation()
        guard let before = columnScreenSpan(column, context: context, state: state) else { return }
        beginManualPrimarySpanResize(column, in: context.workspaceId, orientation: context.orientation)
        let horizontal = context.orientation == .horizontal
        let startSpan = horizontal ? column.cachedWidth : column.cachedHeight
        applyPrimarySpanResize(stretch.span, to: column, orientation: context.orientation)

        let landingDrift = columnScreenSpan(column, context: context, state: state).map { after in
            towardTrailingEdge ? after.lowerBound - before.lowerBound : after.upperBound - before.upperBound
        } ?? 0
        let drift = landingDrift + (towardTrailingEdge ? stretch.keptSideShift : -stretch.keptSideShift)

        if horizontal {
            column.cachedWidth = startSpan
            column.animateWidthTo(
                newWidth: stretch.span,
                clock: animationClock,
                config: context.motion.scaled(windowMovementAnimationConfig),
                displayRefreshRate: displayRefreshRate(in: context.workspaceId),
                animated: context.motion.animationsEnabled
            )
        } else {
            column.cachedHeight = startSpan
            column.animateHeightTo(
                newHeight: stretch.span,
                clock: animationClock,
                config: context.motion.scaled(windowMovementAnimationConfig),
                displayRefreshRate: displayRefreshRate(in: context.workspaceId),
                animated: context.motion.animationsEnabled
            )
        }
        if abs(drift) > 0.5 {
            animateViewDrift(drift, context: context, state: &state)
        }
    }

    private func animateViewDrift(_ drift: CGFloat, context: NiriInteractionContext, state: inout ViewportState) {
        state.animateToOffset(
            state.viewOffset + drift,
            motion: context.motion,
            config: windowMovementAnimationConfig,
            scale: displayScale(in: context.workspaceId)
        )
    }

    func centreColumn(
        _ column: NiriContainer,
        on centre: CGFloat,
        animated: Bool,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let horizontal = context.orientation == .horizontal
        let span = horizontal ? column.settledWidth : column.settledHeight
        let cached = horizontal ? column.cachedWidth : column.cachedHeight
        if horizontal { column.cachedWidth = span } else { column.cachedHeight = span }
        let strip = liveColumnStrip(context: context, state: state)
        if horizontal { column.cachedWidth = cached } else { column.cachedHeight = cached }
        guard let after = strip.first(where: { $0.column === column }) else { return }
        let limits = edgePeekBounds(of: column, context: context)
        let lowest = limits.lowerBound
        let highest = max(lowest, limits.upperBound - span)
        var drift = after.minX - min(max(centre - span / 2, lowest), highest)
        if let centred = fittingStripDrift(strip, context: context) {
            drift = centred
        } else if !centresFocusedColumn(in: context.workspaceId),
                  let ends = keptStripEndsDrift(strip: strip, context: context)
        {
            drift = min(max(drift, ends.lowest), ends.highest)
        }
        guard abs(drift) > 0.5 else { return }
        if animated {
            animateViewDrift(drift, context: context, state: &state)
        } else {
            state.jumpOffset(to: state.viewOffset + drift)
        }
    }

    func centresFocusedColumn(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        let settings = effectiveSettings(in: workspaceId)
        return settings.centerFocusedColumn == .always
            || (settings.alwaysCenterSingleColumn && columns(in: workspaceId).count == 1)
    }
}

extension NiriLayoutEngine {
    func viewportEdgeRules(in workspaceId: WorkspaceDescriptor.ID) -> ViewportEdgeRules {
        ViewportEdgeRules(
            keepsStripEndsOnScreen: policies.keepsStripEndsOnScreen,
            centersFittingStrip: centresFittingStrip(in: workspaceId),
            peeks: edgePeekSpans(in: workspaceId)
        )
    }
}
