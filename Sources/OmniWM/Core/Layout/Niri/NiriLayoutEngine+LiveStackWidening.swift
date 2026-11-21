// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func widenLiveStackForDrop(
        _ column: NiriContainer,
        for window: NiriWindow,
        home: NiriContainer?,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let before = columnScreenSpan(column, context: context, state: state)
        window.deferredMinimumOrientation = nil
        guard let before else { return }
        let startWidth = before.upperBound - before.lowerBound
        let wanted = context.orientation == .horizontal
            ? projectedWidthBounds(for: column, workspaceId: context.workspaceId).min
            : projectedHeightBounds(for: column, workspaceId: context.workspaceId).min
        guard wanted > startWidth + 0.5 else { return }
        beginManualPrimarySpanResize(column, in: context.workspaceId, orientation: context.orientation)
        applyPrimarySpanResize(wanted, to: column, orientation: context.orientation)
        let finalWidth = column.cachedPrimarySpan(orientation: context.orientation)
        let after = columnScreenSpan(column, context: context, state: state)
        column.setCachedPrimarySpan(startWidth, orientation: context.orientation)
        if context.orientation == .horizontal {
            column.animateWidthTo(
                newWidth: finalWidth,
                clock: animationClock,
                config: context.motion.scaled(windowMovementAnimationConfig),
                displayRefreshRate: displayRefreshRate(in: context.workspaceId),
                animated: context.motion.animationsEnabled
            )
        } else {
            column.animateHeightTo(
                newHeight: finalWidth,
                clock: animationClock,
                config: context.motion.scaled(windowMovementAnimationConfig),
                displayRefreshRate: displayRefreshRate(in: context.workspaceId),
                animated: context.motion.animationsEnabled
            )
        }
        column.growsTowardLeadingEdge = liveStackGrowsTowardHome(column, home: home, in: context.workspaceId)
        guard let after, column.growsTowardLeadingEdge else { return }
        animateLiveViewShift(after.upperBound - before.upperBound, context: context, state: &state)
    }

    func anchoredToTrailingEdge(
        _ frame: CGRect,
        of window: NiriWindow,
        in column: NiriContainer,
        orientation: Monitor.Orientation
    ) -> CGRect {
        guard column.growsTowardLeadingEdge else { return frame }
        guard column.hasPrimarySpanAnimation(orientation: orientation) else {
            column.growsTowardLeadingEdge = false
            return frame
        }
        let minimum = window.constraints.normalized().minSize
        if orientation == .horizontal {
            guard minimum.width > frame.width + 0.5 else { return frame }
            return CGRect(x: frame.maxX - minimum.width, y: frame.minY, width: minimum.width, height: frame.height)
        }
        guard minimum.height > frame.height + 0.5 else { return frame }
        return CGRect(x: frame.minX, y: frame.maxY - minimum.height, width: frame.width, height: minimum.height)
    }

    private func liveStackGrowsTowardHome(
        _ column: NiriContainer,
        home: NiriContainer?,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let home,
              let homeIndex = columnIndex(of: home, in: workspaceId),
              let columnIndex = columnIndex(of: column, in: workspaceId)
        else { return false }
        return homeIndex < columnIndex
    }
}
