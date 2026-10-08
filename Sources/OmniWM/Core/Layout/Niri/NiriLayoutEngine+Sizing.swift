// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    private func cachedWidthForResizeStart(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> CGFloat {
        if column.cachedWidth <= 0 {
            if let singleWindowContext = singleWindowLayoutContext(in: workspaceId),
               singleWindowContext.container === column
            {
                column.cachedWidth = resolvedSingleWindowRect(
                    for: singleWindowContext,
                    in: workingFrame,
                    scale: 1.0,
                    gaps: .init(horizontal: gaps, vertical: 0),
                    orientation: .horizontal
                ).width
            } else {
                column.resolveAndCacheWidth(
                    workingAreaWidth: workingFrame.width,
                    gaps: gaps,
                    contentInset: tabContentInset(for: column)
                )
            }
        }

        return column.cachedWidth
    }

    func tabContentInset(for column: NiriContainer) -> CGFloat {
        column.isTabbed ? renderStyle.tabIndicatorWidth : 0
    }

    func isViewportAnchor(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState
    ) -> Bool {
        if let selectedId = state.selectedNodeId,
           column.windowNodes.contains(where: { $0.id == selectedId })
        {
            return true
        }
        return columnIndex(of: column, in: workspaceId) == state.activeColumnIndex
    }

    private func applyColumnWidth(
        _ column: NiriContainer,
        width newWidth: ProportionalSize,
        presetIndex: Int?,
        context: NiriInteractionContext,
        state: inout ViewportState,
        recoversSettledCoverage: Bool = true
    ) {
        cancelInteractiveResize(for: column, in: context.workspaceId)

        column.width = newWidth
        column.presetWidthIdx = presetIndex
        column.isFullWidth = false
        column.savedWidth = nil
        column.hasManualSingleWindowWidthOverride = true

        let targetPixels = column.resolvedWidthPixels(
            newWidth,
            availableSpan: context.workingFrame.width,
            gaps: context.gaps,
            contentInset: tabContentInset(for: column)
        )

        column.animateWidthTo(
            newWidth: targetPixels,
            clock: animationClock,
            config: context.motion.scaled(windowMovementAnimationConfig),
            displayRefreshRate: displayRefreshRate(in: context.workspaceId),
            animated: context.motion.animationsEnabled
        )

        guard isViewportAnchor(column, in: context.workspaceId, state: state) else { return }
        if context.orientation == .horizontal {
            ensureContainerSelectionVisible(column, context: context, state: &state)
        }
        if recoversSettledCoverage {
            recoverSettledCoverage(
                context: context,
                state: &state
            )
        }
    }

    private func ensureContainerSelectionVisible(
        _ column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        guard let window = column.activeWindow ?? column.windowNodes.first else { return }
        ensureSelectionVisible(node: window, context: context, state: &state)
    }

    private func applyContainerHeight(
        _ column: NiriContainer,
        height newHeight: ProportionalSize,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        cancelInteractiveResize(for: column, in: context.workspaceId)

        column.height = newHeight
        column.isFullHeight = false
        column.savedHeight = nil
        column.hasManualSingleWindowHeightOverride = true
        column.cachedHeight = column.resolvedHeightPixels(
            newHeight,
            availableSpan: context.workingFrame.height,
            gaps: context.gaps
        )

        let verticalContext = context.oriented(.vertical)
        guard isViewportAnchor(column, in: context.workspaceId, state: state) else { return }
        ensureContainerSelectionVisible(column, context: verticalContext, state: &state)
        recoverSettledCoverage(context: verticalContext, state: &state)
    }

    private func toggleContainerHeight(
        _ column: NiriContainer,
        forwards: Bool,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let currentHeight = column.currentHeightForSizing(
            workingAreaHeight: context.workingFrame.height,
            gaps: context.gaps
        )
        let nextIndex = column.nextHeightPresetIndex(
            forwards: forwards,
            currentHeight: currentHeight,
            presets: presetContainerPrimarySpans,
            availableSpan: context.workingFrame.height,
            gaps: context.gaps
        )

        let currentSpec = column.isFullHeight ? ProportionalSize.proportion(1) : column.height
        let newHeight = NiriSizeChange(presetContainerPrimarySpans[nextIndex]).primarySpanSpec(
            currentSpec: currentSpec,
            currentPixels: currentHeight,
            axisSpan: context.workingFrame.height,
            gaps: context.gaps
        )
        applyContainerHeight(
            column,
            height: newHeight,
            context: context,
            state: &state
        )
    }

    private func toggleFullHeight(
        _ column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: .vertical
        )
        let containers = columns(in: context.workspaceId)
        let activeIndex = state.activeColumnIndex.clamped(to: 0 ... max(0, containers.count - 1))
        let previousActivePosition = state.containerPosition(
            at: activeIndex,
            containers: containers,
            gap: context.gaps,
            sizeKeyPath: \.cachedHeight
        )
        let previousHeight = column.currentHeightForSizing(
            workingAreaHeight: context.workingFrame.height,
            gaps: context.gaps
        )
        cancelInteractiveResize(for: column, in: context.workspaceId)
        let effectiveHeight = column.toggleFullHeightSpec()
        column.cachedHeight = column.resolvedHeightPixels(
            effectiveHeight,
            availableSpan: context.workingFrame.height,
            gaps: context.gaps
        )

        guard abs(column.cachedHeight - previousHeight) > 0.001 else { return }

        let settings = effectiveSettings(in: context.workspaceId)
        let verticalContext = context.oriented(.vertical)
        guard isViewportAnchor(column, in: context.workspaceId, state: state) else { return }
        if settings.centerFocusedColumn == .always
            || (settings.alwaysCenterSingleColumn && containers.count == 1)
        {
            ensureContainerSelectionVisible(column, context: verticalContext, state: &state)
        } else {
            let currentActivePosition = state.containerPosition(
                at: activeIndex,
                containers: containers,
                gap: context.gaps,
                sizeKeyPath: \.cachedHeight
            )
            state.rebaseOffset(by: previousActivePosition - currentActivePosition)
        }
        recoverSettledCoverage(context: verticalContext, state: &state)
    }

    func toggleContainerPrimarySpan(
        _ column: NiriContainer,
        forwards: Bool,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        assertSanctionedMutation()
        guard !presetContainerPrimarySpans.isEmpty else { return }
        beginManualPrimarySpanResize(column, in: context.workspaceId, orientation: context.orientation)
        if context.orientation == .vertical {
            toggleContainerHeight(
                column,
                forwards: forwards,
                context: context,
                state: &state
            )
            return
        }

        let previousWidth = cachedWidthForResizeStart(
            column,
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps
        )

        let nextIdx = nextContainerWidthPresetIndex(
            column,
            currentPixels: previousWidth,
            forwards: forwards,
            context: context
        )

        let currentSpec = column.isFullWidth ? ProportionalSize.proportion(1) : column.width
        let newWidth = NiriSizeChange(presetContainerPrimarySpans[nextIdx]).primarySpanSpec(
            currentSpec: currentSpec,
            currentPixels: previousWidth,
            axisSpan: context.workingFrame.width,
            gaps: context.gaps
        )

        applyColumnWidth(
            column,
            width: newWidth,
            presetIndex: nextIdx,
            context: context,
            state: &state
        )
    }

    private func nextContainerWidthPresetIndex(
        _ column: NiriContainer,
        currentPixels: CGFloat,
        forwards: Bool,
        context: NiriInteractionContext
    ) -> Int {
        let presetCount = presetContainerPrimarySpans.count

        let nextIdx: Int
        if !column.isFullWidth, let currentIdx = column.presetWidthIdx {
            if forwards {
                nextIdx = (currentIdx + 1) % presetCount
            } else {
                nextIdx = (currentIdx - 1 + presetCount) % presetCount
            }
        } else {
            let currentTile: CGFloat
            if let singleWindowContext = singleWindowLayoutContext(in: context.workspaceId),
               singleWindowContext.container === column,
               !column.hasManualSingleWindowWidthOverride
            {
                currentTile = column.resolvedWidthPixels(
                    column.width,
                    availableSpan: context.workingFrame.width,
                    gaps: context.gaps,
                    contentInset: tabContentInset(for: column)
                )
            } else {
                currentTile = currentPixels
            }

            if forwards {
                nextIdx = presetContainerPrimarySpans.firstIndex { preset in
                    currentTile + 1 < column.resolvedWidthPixels(
                        preset.asProportionalSize,
                        availableSpan: context.workingFrame.width,
                        gaps: context.gaps,
                        contentInset: tabContentInset(for: column)
                    )
                } ?? 0
            } else {
                let matchingIndex = presetContainerPrimarySpans.lastIndex { preset in
                    column.resolvedWidthPixels(
                        preset.asProportionalSize,
                        availableSpan: context.workingFrame.width,
                        gaps: context.gaps,
                        contentInset: tabContentInset(for: column)
                    ) + 1 < currentTile
                }
                nextIdx = matchingIndex ?? (presetCount - 1)
            }
        }
        return nextIdx
    }

    func setContainerPrimarySpan(
        _ column: NiriContainer,
        change: NiriSizeChange,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        assertSanctionedMutation()
        beginManualPrimarySpanResize(column, in: context.workspaceId, orientation: context.orientation)
        if context.orientation == .vertical {
            let previousHeight = column.currentHeightForSizing(
                workingAreaHeight: context.workingFrame.height,
                gaps: context.gaps
            )
            let currentSpec = column.isFullHeight ? ProportionalSize.proportion(1) : column.height
            let newHeight = change.primarySpanSpec(
                currentSpec: currentSpec,
                currentPixels: previousHeight,
                axisSpan: context.workingFrame.height,
                gaps: context.gaps
            )
            applyContainerHeight(
                column,
                height: newHeight,
                context: context,
                state: &state
            )
            return
        }

        let currentSpec = column.isFullWidth ? ProportionalSize.proportion(1) : column.width
        let currentPixels = column.resolvedWidthPixels(
            currentSpec,
            availableSpan: context.workingFrame.width,
            gaps: context.gaps,
            contentInset: tabContentInset(for: column)
        )
        let newWidth = change.primarySpanSpec(
            currentSpec: currentSpec,
            currentPixels: currentPixels,
            axisSpan: context.workingFrame.width,
            gaps: context.gaps
        )

        applyColumnWidth(
            column,
            width: newWidth,
            presetIndex: nil,
            context: context,
            state: &state
        )
    }

    func toggleContainerFullPrimarySpan(
        _ column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        assertSanctionedMutation()
        beginManualPrimarySpanResize(column, in: context.workspaceId, orientation: context.orientation)
        if context.orientation == .vertical {
            toggleFullHeight(
                column,
                context: context,
                state: &state
            )
            return
        }

        cancelInteractiveResize(for: column, in: context.workspaceId)
        let targetSpec = column.toggleFullWidthSpec()
        let targetPixels = column.resolvedWidthPixels(
            targetSpec,
            availableSpan: context.workingFrame.width,
            gaps: context.gaps,
            contentInset: tabContentInset(for: column)
        )

        column.animateWidthTo(
            newWidth: targetPixels,
            clock: animationClock,
            config: context.motion.scaled(windowMovementAnimationConfig),
            displayRefreshRate: displayRefreshRate(in: context.workspaceId),
            animated: context.motion.animationsEnabled
        )

        guard isViewportAnchor(column, in: context.workspaceId, state: state) else { return }
        if context.orientation == .horizontal {
            ensureContainerSelectionVisible(column, context: context, state: &state)
        }
        recoverSettledCoverage(
            context: context,
            state: &state
        )
    }

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
