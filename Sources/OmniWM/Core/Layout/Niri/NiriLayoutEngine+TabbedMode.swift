// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    func updateTabIndicatorWidth(_ width: CGFloat, motion: MotionSnapshot) {
        assertSanctionedMutation()
        guard renderStyle.tabIndicatorWidth != width else { return }
        renderStyle.tabIndicatorWidth = width

        for (workspaceId, state) in states {
            for column in state.root.columns where column.isTabbed {
                cancelResizeForDisplayChange(column)
                let previousWidth = column.cachedWidth
                if previousWidth > 0 {
                    column.cachedWidth = column.clampedToWidthBounds(previousWidth, contentInset: width)
                }
                if let target = column.targetWidth {
                    let clampedTarget = column.clampedToWidthBounds(target, contentInset: width)
                    if clampedTarget != target || column.cachedWidth != previousWidth {
                        column.animateWidthTo(
                            newWidth: clampedTarget,
                            clock: animationClock,
                            config: motion.scaled(windowMovementAnimationConfig),
                            displayRefreshRate: displayRefreshRate(in: workspaceId),
                            animated: motion.animationsEnabled
                        )
                    }
                }
            }
        }
    }

    @discardableResult
    func toggleColumnTabbed(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        orientation: Monitor.Orientation
    ) -> Bool {
        assertSanctionedMutation()
        let newMode: ColumnDisplay = column.displayMode == .normal ? .tabbed : .normal
        return setColumnDisplay(
            newMode,
            for: column,
            in: workspaceId,
            motion: motion,
            orientation: orientation
        )
    }

    @discardableResult
    func setColumnDisplay(
        _ mode: ColumnDisplay,
        for column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        orientation: Monitor.Orientation,
        gaps: CGFloat = 0
    ) -> Bool {
        guard column.displayMode != mode else { return false }

        cancelResizeForDisplayChange(column)

        let windows = projectedWindows(in: column, workspaceId: workspaceId)
        guard !windows.isEmpty else {
            column.displayMode = mode
            return true
        }

        let prevOrigin = projectedTilesOrigin(
            displayMode: column.displayMode,
            visibleWindowCount: windows.count
        )

        column.displayMode = mode
        let newOrigin = projectedTilesOrigin(
            displayMode: column.displayMode,
            visibleWindowCount: windows.count
        )
        let originDelta = CGPoint(x: prevOrigin.x - newOrigin.x, y: prevOrigin.y - newOrigin.y)

        if windows.count > 1 {
            let tileOffsets = projectedSecondaryOffsets(
                for: windows,
                effectiveTabbed: false,
                gaps: gaps,
                orientation: orientation
            )

            for (idx, window) in windows.enumerated() {
                let delta = tabTransitionDelta(
                    tileOffset: idx < tileOffsets.count ? tileOffsets[idx] : 0,
                    prevOrigin: prevOrigin, originDelta: originDelta, mode: mode, orientation: orientation
                )
                if delta.x != 0 || delta.y != 0 {
                    window.animateMoveFrom(
                        displacement: delta,
                        clock: animationClock,
                        config: motion.scaled(windowMovementAnimationConfig),
                        displayRefreshRate: displayRefreshRate(in: workspaceId),
                        animated: motion.animationsEnabled
                    )
                }
            }
        }

        clampTabbedColumnWidth(column, in: workspaceId, motion: motion)
        updateTabbedColumnVisibility(column: column)

        return true
    }

    private func tabTransitionDelta(
        tileOffset: CGFloat, prevOrigin: CGPoint, originDelta: CGPoint,
        mode: ColumnDisplay, orientation: Monitor.Orientation
    ) -> CGPoint {
        let previousSecondaryOrigin = switch orientation {
        case .horizontal: prevOrigin.y
        case .vertical: prevOrigin.x
        }
        var secondaryDelta = tileOffset
        secondaryDelta -= previousSecondaryOrigin

        if mode == .normal {
            secondaryDelta *= -1
        }

        return switch orientation {
        case .horizontal:
            CGPoint(x: originDelta.x, y: originDelta.y + secondaryDelta)
        case .vertical:
            CGPoint(x: originDelta.x + secondaryDelta, y: originDelta.y)
        }
    }

    private func cancelResizeForDisplayChange(_ column: NiriContainer) {
        if let resize = interactiveResize,
           let resizeWindow = findNode(by: resize.windowId, in: resize.workspaceId) as? NiriWindow,
           let resizeColumn = findColumn(containing: resizeWindow, in: resize.workspaceId),
           resizeColumn.id == column.id
        {
            clearInteractiveResize()
        }
    }

    private func clampTabbedColumnWidth(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot
    ) {
        let currentTarget = column.settledWidth
        if currentTarget > 0 {
            let clampedTarget = column.clampedToWidthBounds(
                currentTarget,
                contentInset: tabContentInset(for: column)
            )
            if clampedTarget != currentTarget {
                column.animateWidthTo(
                    newWidth: clampedTarget,
                    clock: animationClock,
                    config: motion.scaled(windowMovementAnimationConfig),
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: motion.animationsEnabled
                )
            }
        }
    }

    func updateTabbedColumnVisibility(column: NiriContainer) {
        assertSanctionedMutation()
        let windows = column.windowNodes
        guard !windows.isEmpty else { return }

        column.clampActiveTileIdx()

        if column.displayMode == .tabbed {
            for (idx, window) in windows.enumerated() {
                let isActive = idx == column.activeTileIdx
                window.isHiddenInTabbedMode = !isActive
            }
        } else {
            for window in windows {
                window.isHiddenInTabbedMode = false
            }
        }
    }
}
