// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct ColumnStretch: Equatable {
    let width: CGFloat
    let keptSideShift: CGFloat
}

private struct StretchedStrip {
    let placed: ClosedRange<CGFloat>
    let start: CGFloat
    let end: CGFloat
    let rightSide: Bool

    var lead: CGFloat {
        placed.lowerBound - start
    }

    var rest: CGFloat {
        end - start - (placed.upperBound - placed.lowerBound)
    }

    func keptStart(width: CGFloat) -> CGFloat {
        rightSide ? start : placed.upperBound - width - lead
    }

    func reachesWhenPlaced(at target: CGFloat, context: NiriInteractionContext) -> [CGFloat] {
        let frame = context.workingFrame
        if rightSide {
            return [
                target - (frame.minX + context.gaps) - lead,
                2 * (target - frame.minX - lead) - (frame.width - rest)
            ]
        }
        return [
            frame.maxX - context.gaps - rest + lead - target,
            frame.width - rest - 2 * (target - frame.minX - lead)
        ]
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
        rightSide: Bool,
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
            rightSide: rightSide
        )
        let limits = edgePeekBounds(of: column, context: context)
        let target = rightSide ? limits.upperBound : limits.lowerBound
        let keptReach = rightSide ? target - placed.minX : placed.maxX - target
        let bounds = projectedWidthBounds(for: column, workspaceId: context.workspaceId)
        let widest = min(context.workingFrame.width - 2 * context.gaps, bounds.max ?? .infinity)
        let candidates = [keptReach] + stretched.reachesWhenPlaced(at: target, context: context)
        let requested = candidates
            .map { max(bounds.min, min($0, widest)) }
            .min { candidate, other in
                abs(farEdge(of: stretched, width: candidate, context: context) - target)
                    < abs(farEdge(of: stretched, width: other, context: context) - target) - 0.5
            } ?? keptReach
        let width = column.resolvedWidthPixels(
            .fixed(requested),
            availableSpan: context.workingFrame.width,
            gaps: context.gaps,
            contentInset: tabContentInset(for: column)
        )
        let settled = settledSpan(of: stretched, width: width, context: context)
        let moved = rightSide ? placed.minX - settled.lowerBound : settled.upperBound - placed.maxX
        let overshoot = abs(moved) < 0.5 ? max(0, width - max(requested, keptReach)) : 0
        return ColumnStretch(width: width, keptSideShift: moved + overshoot)
    }

    private func farEdge(of stretched: StretchedStrip, width: CGFloat, context: NiriInteractionContext) -> CGFloat {
        let span = settledSpan(of: stretched, width: width, context: context)
        return stretched.rightSide ? span.upperBound : span.lowerBound
    }

    private func settledSpan(
        of stretched: StretchedStrip,
        width: CGFloat,
        context: NiriInteractionContext
    ) -> ClosedRange<CGFloat> {
        let frame = context.workingFrame
        let span = stretched.rest + width
        var start = stretched.keptStart(width: width)
        if centresFittingStrip(in: context.workspaceId),
           let offset = ViewportState.centredStripOffset(
               stripSpan: span,
               viewSpan: frame.width,
               gap: context.gaps,
               scale: displayScale(in: context.workspaceId)
           )
        {
            start = frame.minX - offset
        } else if keepsStripEndsOnScreen,
                  !centresFocusedColumn(in: context.workspaceId),
                  ViewportState.stripEndOffsets(stripSpan: span, viewSpan: frame.width, gap: context.gaps) != nil
        {
            start = min(max(start, frame.maxX - context.gaps - span), frame.minX + context.gaps)
        }
        let minX = start + stretched.lead
        return minX ... minX + width
    }

    func stretchColumn(
        _ column: NiriContainer,
        to stretch: ColumnStretch,
        rightSide: Bool,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        assertSanctionedMutation()
        guard let before = columnScreenSpan(column, context: context, state: state) else { return }
        beginManualPrimarySpanResize(column, in: context.workspaceId, orientation: context.orientation)
        let startWidth = column.cachedWidth
        applyPrimarySpanResize(stretch.width, to: column, orientation: .horizontal)

        let landingDrift = columnScreenSpan(column, context: context, state: state).map { after in
            rightSide ? after.lowerBound - before.lowerBound : after.upperBound - before.upperBound
        } ?? 0
        let drift = landingDrift + (rightSide ? stretch.keptSideShift : -stretch.keptSideShift)

        column.cachedWidth = startWidth
        column.animateWidthTo(
            newWidth: stretch.width,
            clock: animationClock,
            config: context.motion.scaled(windowMovementAnimationConfig),
            displayRefreshRate: displayRefreshRate(in: context.workspaceId),
            animated: context.motion.animationsEnabled
        )
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
        let width = column.settledWidth
        let startWidth = column.cachedWidth
        column.cachedWidth = width
        let strip = liveColumnStrip(context: context, state: state)
        column.cachedWidth = startWidth
        guard let after = strip.first(where: { $0.column === column }) else { return }
        let limits = edgePeekBounds(of: column, context: context)
        let lowest = limits.lowerBound
        let highest = max(lowest, limits.upperBound - width)
        var drift = after.minX - min(max(centre - width / 2, lowest), highest)
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
            keepsStripEndsOnScreen: keepsStripEndsOnScreen,
            centersFittingStrip: centresFittingStrip(in: workspaceId),
            peeks: edgePeekWidths(in: workspaceId)
        )
    }
}
