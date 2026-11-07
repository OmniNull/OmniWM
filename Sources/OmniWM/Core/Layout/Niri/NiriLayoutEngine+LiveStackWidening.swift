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
        window.defersMinimumWidth = false
        guard context.orientation == .horizontal, let before else { return }
        let startWidth = before.upperBound - before.lowerBound
        let wanted = projectedWidthBounds(for: column, workspaceId: context.workspaceId).min
        guard wanted > startWidth + 0.5 else { return }
        beginManualPrimarySpanResize(column, in: context.workspaceId, orientation: .horizontal)
        applyPrimarySpanResize(wanted, to: column, orientation: .horizontal)
        let finalWidth = column.cachedWidth
        let after = columnScreenSpan(column, context: context, state: state)
        column.cachedWidth = startWidth
        column.animateWidthTo(
            newWidth: finalWidth,
            clock: animationClock,
            config: context.motion.scaled(windowMovementAnimationConfig),
            displayRefreshRate: displayRefreshRate(in: context.workspaceId),
            animated: context.motion.animationsEnabled
        )
        column.growsTowardLeadingEdge = liveStackGrowsTowardHome(column, home: home, in: context.workspaceId)
        guard let after, column.growsTowardLeadingEdge else { return }
        animateLiveViewShift(after.upperBound - before.upperBound, context: context, state: &state)
    }

    func anchoredToTrailingEdge(_ frame: CGRect, of window: NiriWindow, in column: NiriContainer) -> CGRect {
        guard column.growsTowardLeadingEdge else { return frame }
        guard column.hasWidthAnimationRunning else {
            column.growsTowardLeadingEdge = false
            return frame
        }
        let minimum = window.constraints.normalized().minSize.width
        guard minimum > frame.width + 0.5 else { return frame }
        return CGRect(x: frame.maxX - minimum, y: frame.minY, width: minimum, height: frame.height)
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
