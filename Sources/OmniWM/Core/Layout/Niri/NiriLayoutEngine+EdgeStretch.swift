// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct ColumnStretch: Equatable {
    let width: CGFloat
    let keptSideShift: CGFloat
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
        guard let span = columnScreenSpan(column, context: context, state: state) else { return nil }
        let reach = rightSide
            ? context.workingFrame.maxX - context.gaps - span.lowerBound
            : span.upperBound - (context.workingFrame.minX + context.gaps)
        let bounds = projectedWidthBounds(for: column, workspaceId: context.workspaceId)
        let widest = min(context.workingFrame.width - 2 * context.gaps, bounds.max ?? .infinity)
        let requested = max(bounds.min, min(reach, widest))
        let width = column.resolvedWidthPixels(
            .fixed(requested),
            availableSpan: context.workingFrame.width,
            gaps: context.gaps,
            contentInset: tabContentInset(for: column)
        )
        return ColumnStretch(width: width, keptSideShift: max(0, width - max(requested, reach)))
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

    func cycleColumnWidthAroundCentre(
        _ column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let before = columnScreenSpan(column, context: context, state: state)
        toggleContainerPrimarySpan(column, forwards: true, context: context, state: &state)
        guard context.orientation == .horizontal,
              let before,
              !(isViewportAnchor(column, in: context.workspaceId, state: state)
                  && centresFocusedColumn(in: context.workspaceId))
        else { return }
        centreColumn(
            column,
            on: (before.lowerBound + before.upperBound) / 2,
            animated: true,
            context: context,
            state: &state
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
        let lowest = context.workingFrame.minX + context.gaps
        let highest = max(lowest, context.workingFrame.maxX - context.gaps - width)
        var drift = after.minX - min(max(centre - width / 2, lowest), highest)
        if !centresFocusedColumn(in: context.workspaceId),
           let ends = stripEndsDrift(strip: strip, context: context),
           ends.lowest <= ends.highest + FrameTolerance.screenMatch
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

    private func centresFocusedColumn(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        let settings = effectiveSettings(in: workspaceId)
        return settings.centerFocusedColumn == .always
            || (settings.alwaysCenterSingleColumn && columns(in: workspaceId).count == 1)
    }
}
