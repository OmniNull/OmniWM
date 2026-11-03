// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension NiriLayoutEngine {
    struct ResizeUpdateContext {
        let resize: InteractiveResize
        let delta: CGPoint
        let monitorFrame: CGRect
        let gaps: LayoutGaps
    }

    func resizeHorizontalColumn(
        _ column: NiriContainer, context: ResizeUpdateContext,
        viewportState: ((inout ViewportState) -> Void) -> Void
    ) -> Bool {
        guard context.resize.edges.hasHorizontal else { return false }
        return resizeColumnPrimarySpan(column, context: context, viewportState: viewportState)
    }

    func resizeHorizontalWindow(
        _ windowNode: NiriWindow, column: NiriContainer, context: ResizeUpdateContext
    ) -> Bool {
        let resize = context.resize
        let delta = context.delta
        let monitorFrame = context.monitorFrame
        let gaps = context.gaps
        var changed = false
        if resize.edges.hasVertical,
           case let .weight(originalHeight)? = resize.originalWindowBaseline
        {
            var dy = delta.y

            if resize.edges.contains(.bottom) {
                dy = -dy
            }

            let pixelsPerWeight = calculateVerticalPixelsPerWeightUnit(
                column: column,
                workspaceId: resize.workspaceId,
                monitorFrame: monitorFrame,
                gaps: gaps
            )

            if pixelsPerWeight > 0 {
                let weightDelta = dy / pixelsPerWeight
                let newWeight = originalHeight + weightDelta
                windowNode.size = newWeight.clamped(
                    to: resizeConfiguration.minWindowWeight ... resizeConfiguration.maxWindowWeight
                )
                changed = true
            }
        }
        return changed
    }

    func resizeVerticalWindow(
        _ windowNode: NiriWindow, column: NiriContainer, context: ResizeUpdateContext
    ) -> Bool {
        let resize = context.resize
        let delta = context.delta
        let monitorFrame = context.monitorFrame
        let gaps = context.gaps
        var changed = false
        if resize.edges.hasHorizontal, let windowBaseline = resize.originalWindowBaseline {
            var dx = delta.x

            if resize.edges.contains(.left) {
                dx = -dx
            }

            switch windowBaseline {
            case let .fixedPixels(originalWidth):
                let constraints = windowNode.constraints.normalized()
                let minWidth = constraints.minSize.width
                let viewportMaxWidth = monitorFrame.width - 2 * gaps.horizontal
                let constrainedMaxWidth = constraints.hasMaxWidth
                    ? constraints.maxSize.width
                    : viewportMaxWidth
                let maxWidth = max(minWidth, min(viewportMaxWidth, constrainedMaxWidth))
                let newWidth = (originalWidth + dx).clamped(to: minWidth ... maxWidth)
                windowNode.windowWidth = .fixed(newWidth)
                changed = true
            case let .weight(originalWidthWeight):
                let pixelsPerWeight = calculateHorizontalPixelsPerWeightUnit(
                    column: column,
                    workspaceId: resize.workspaceId,
                    monitorFrame: monitorFrame,
                    gaps: gaps
                )

                if pixelsPerWeight > 0 {
                    let weightDelta = dx / pixelsPerWeight
                    let newWeight = (originalWidthWeight + weightDelta).clamped(
                        to: resizeConfiguration.minWindowWeight ... resizeConfiguration.maxWindowWeight
                    )
                    let constrainedWidth = windowNode.constraints.clampWidth(
                        newWeight * pixelsPerWeight
                    )
                    windowNode.windowWidth = .auto(weight: constrainedWidth / pixelsPerWeight)
                    changed = true
                }
            }
        }
        return changed
    }

    func resizeVerticalColumn(
        _ column: NiriContainer, context: ResizeUpdateContext,
        viewportState: ((inout ViewportState) -> Void) -> Void
    ) -> Bool {
        guard context.resize.edges.hasVertical else { return false }
        return resizeColumnPrimarySpan(column, context: context, viewportState: viewportState)
    }

    private func resizeColumnPrimarySpan(
        _ column: NiriContainer, context: ResizeUpdateContext,
        viewportState: ((inout ViewportState) -> Void) -> Void
    ) -> Bool {
        let resize = context.resize
        guard let originalSpan = resize.originalContainerSpan else { return false }
        let horizontal = resize.orientation == .horizontal
        let leadingEdge = horizontal ? resize.edges.contains(.left) : resize.edges.contains(.bottom)
        let delta = horizontal ? context.delta.x : context.delta.y
        let gap = horizontal ? context.gaps.horizontal : context.gaps.vertical
        let workingSpan = horizontal ? context.monitorFrame.width : context.monitorFrame.height
        let bounds = horizontal
            ? projectedWidthBounds(for: column, workspaceId: resize.workspaceId)
            : projectedHeightBounds(for: column, workspaceId: resize.workspaceId)
        let viewportMaxSpan = workingSpan - 2 * gap
        let maximumSpan = max(bounds.min, min(viewportMaxSpan, bounds.max ?? viewportMaxSpan))
        let requestedSpan = originalSpan + (leadingEdge ? -delta : delta)
        let span = constrainedProjectedPrimarySpan(
            requestedSpan.clamped(to: bounds.min ... maximumSpan),
            for: NiriProjectedColumn(
                column: column,
                windows: projectedWindows(in: column, workspaceId: resize.workspaceId),
                durableIndex: resize.columnIndex
            ),
            workingFrame: context.monitorFrame,
            gap: gap,
            orientation: resize.orientation
        )
        let currentSpan = horizontal ? column.cachedWidth : column.cachedHeight
        guard span != currentSpan else { return false }
        beginManualPrimarySpanResize(column, in: resize.workspaceId, orientation: resize.orientation)
        applyPrimarySpanResize(span, to: column, orientation: resize.orientation)
        if leadingEdge, let originalOffset = resize.originalViewOffset {
            viewportState { state in
                state.jumpOffset(to: originalOffset + span - originalSpan)
            }
        }
        return true
    }

    private func applyPrimarySpanResize(
        _ span: CGFloat, to column: NiriContainer, orientation: Monitor.Orientation
    ) {
        switch orientation {
        case .horizontal:
            column.widthAnimation = nil
            column.targetWidth = nil
            column.cachedWidth = span
            column.width = .fixed(span)
            column.presetWidthIdx = nil
            column.isFullWidth = false
            column.savedWidth = nil
            column.hasManualSingleWindowWidthOverride = true
        case .vertical:
            column.heightAnimation = nil
            column.targetHeight = nil
            column.cachedHeight = span
            column.height = .fixed(span)
            column.isFullHeight = false
            column.savedHeight = nil
            column.hasManualSingleWindowHeightOverride = true
        }
    }
}
