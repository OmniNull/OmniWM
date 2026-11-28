// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension NiriLayoutEngine {
    func correctViewportAfterColumnRemoval(
        context: NiriInteractionContext,
        state: inout ViewportState,
        preservesCenteredView: Bool = false
    ) -> Bool {
        let cols = columns(in: context.workspaceId)
        guard !cols.isEmpty else { return false }

        let monitor = monitorForWorkspace(context.workspaceId)
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame, gaps: context.gaps,
            orientation: context.orientation, motion: context.motion
        )
        let sizeKeyPath = context.orientation.settledSpanKeyPath
        let activeIdx = state.activeColumnIndex.clamped(to: 0 ... (cols.count - 1))
        state.activeColumnIndex = activeIdx
        let activePosition = state.containerPosition(
            at: activeIdx, containers: cols, gap: context.gaps, sizeKeyPath: sizeKeyPath
        )
        let settings = effectiveSettings(in: context.workspaceId)
        let bounds = state.preservesGestureOffset ? NiriViewportGeometry(
            gap: context.gaps, viewportSpan: context.primarySpan, orientation: context.orientation,
            edgeOverscroll: settings.edgeOverscroll
        ).overscrollBounds(columns: cols) : nil
        let viewStart = activePosition + state.viewOffset
        let settle = NiriViewportSettle(
            activePosition: activePosition, viewStart: viewStart, viewportSpan: context.primarySpan, gap: context.gaps,
            centerMode: settings.centerFocusedColumn, keepsStripEndsOnScreen: policies.keepsStripEndsOnScreen,
            preservesCenteredView: preservesCenteredView
        )
        let scale = bounds == nil ? displayScale(in: context.workspaceId) : 2.0
        let offset = settle.correction(
            overscrollBounds: bounds,
            centersStrip: centresWholeStrip(cols, context: context),
            stripSpan: { state.totalSpan(containers: cols, gap: context.gaps, sizeKeyPath: sizeKeyPath) },
            adjacentPairOverflows: {
                let activeSpan = cols[activeIdx][keyPath: sizeKeyPath]
                return activeIdx > 0 && cols[activeIdx - 1][keyPath: sizeKeyPath] + activeSpan + context.gaps * 3
                    > context.primarySpan
                    || activeIdx + 1 < cols.count && activeSpan + cols[activeIdx + 1][keyPath: sizeKeyPath] + context
                    .gaps * 3
                    > context.primarySpan
            },
            visibleOffset: { proposedStart, mode, usesEdges in
                state.computeVisibleOffset(
                    containerIndex: activeIdx, containers: cols, context: context, currentViewStart: proposedStart,
                    centerMode: mode, alwaysCenterSingleColumn: usesEdges && settings.alwaysCenterSingleColumn,
                    edges: usesEdges ? viewportEdgeRules(in: context.workspaceId) : .init(),
                    scale: scale, viewFrame: monitor?.frame
                )
            }
        )
        guard let offset else { return false }
        state.animateToOffset(offset, motion: context.motion, scale: scale)
        return true
    }
}
