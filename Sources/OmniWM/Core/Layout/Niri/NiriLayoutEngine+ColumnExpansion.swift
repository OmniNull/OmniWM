// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func expandContainerToAvailablePrimarySpan(
        _ column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        assertSanctionedMutation()
        switch context.orientation {
        case .horizontal:
            guard !column.isFullWidth else { return }
        case .vertical:
            guard !column.isFullHeight else { return }
        }
        guard column.windowNodes.allSatisfy({ $0.sizingMode == .normal }) else { return }

        if centerFocusedColumn == .always || context.orientation == .vertical {
            toggleContainerFullPrimarySpan(
                column,
                context: context,
                state: &state
            )
            return
        }

        var resultingWidth: CGFloat?
        _ = withProjectedViewport(
            state: &state,
            context: context
        ) { columns, projectedState in
            guard let plan = NiriColumnExpansionPlan(
                column: column,
                columns: columns,
                state: projectedState,
                context: context,
                scale: displayScale(in: context.workspaceId)
            ) else { return }
            resultingWidth = applyColumnExpansion(plan, to: column, context: context, state: &projectedState)
        }
        if let resultingWidth {
            column.cachedWidth = resultingWidth
        }
    }

    private func applyColumnExpansion(
        _ plan: NiriColumnExpansionPlan,
        to column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> CGFloat? {
        if !plan.countedNonActiveColumn {
            toggleContainerFullPrimarySpan(column, context: context, state: &state)
            return column.cachedWidth
        }

        guard let leftmostColX = plan.leftmostColumnX, let activeColX = plan.activeColumnX else { return nil }
        let targetWidth = (column.cachedWidth + plan.availableWidth).clamped(to: 1 ... NiriSizeChange.maxPixels)
        beginManualPrimarySpanResize(column, in: context.workspaceId, orientation: context.orientation)
        applyColumnWidth(
            column,
            width: .fixed(targetWidth),
            presetIndex: nil,
            context: context,
            state: &state,
            recoversSettledCoverage: false
        )
        let resultingWidth = column.cachedWidth
        let targetOffset = leftmostColX - context.gaps - activeColX
        state.animateToOffset(
            targetOffset,
            motion: context.motion,
            scale: displayScale(in: context.workspaceId)
        )
        recoverSettledCoverage(
            context: context,
            state: &state
        )
        return resultingWidth
    }
}
