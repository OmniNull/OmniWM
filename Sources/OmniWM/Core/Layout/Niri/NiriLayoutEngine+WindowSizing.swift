// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension NiriLayoutEngine {
    func calculateVerticalPixelsPerWeightUnit(
        column: NiriContainer,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        gaps: LayoutGaps
    ) -> CGFloat {
        let windows = projectedWindows(in: column, workspaceId: workspaceId)
        guard !windows.isEmpty else { return 0 }

        let totalWeight = windows.reduce(CGFloat(0)) { $0 + $1.size }
        guard totalWeight > 0 else { return 0 }

        let totalGaps = CGFloat(windows.count + 1) * gaps.vertical
        let usableHeight = monitorFrame.height - totalGaps

        return usableHeight / totalWeight
    }

    func setWindowSizingMode(
        _ window: NiriWindow,
        motion: MotionSnapshot,
        mode: SizingMode,
        state: inout ViewportState
    ) {
        let previousMode = window.sizingMode

        if previousMode == mode {
            return
        }

        if previousMode == .fullscreen, mode == .normal {
            if let savedHeight = window.savedHeight {
                window.height = savedHeight
                window.savedHeight = nil
            }

            if let savedOffset = state.viewOffsetToRestore {
                state.animateViewOffsetRestore(savedOffset, motion: motion)
            }
        }

        if previousMode == .normal, mode == .fullscreen {
            window.savedHeight = window.height
            state.saveViewOffsetForFullscreen()
            window.stopMoveAnimations()
        }

        window.sizingMode = mode
    }

    func toggleFullscreen(
        _ window: NiriWindow,
        motion: MotionSnapshot,
        state: inout ViewportState
    ) {
        assertSanctionedMutation()
        let newMode: SizingMode = window.sizingMode == .fullscreen ? .normal : .fullscreen
        setWindowSizingMode(window, motion: motion, mode: newMode, state: &state)
    }

    func toggleWindowPrimarySpan(
        _ window: NiriWindow,
        forwards: Bool,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        assertSanctionedMutation()
        guard let column = findColumn(containing: window, in: context.workspaceId) else { return }
        toggleContainerPrimarySpan(
            column,
            forwards: forwards,
            context: context,
            state: &state
        )
    }

    func setWindowPrimarySpan(
        _ window: NiriWindow,
        change: NiriSizeChange,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        assertSanctionedMutation()
        guard let column = findColumn(containing: window, in: context.workspaceId) else { return }
        setContainerPrimarySpan(
            column,
            change: change,
            context: context,
            state: &state
        )
    }

    func availableWindowWidth(
        in column: NiriContainer,
        projectedWindowCount: Int,
        workingFrame: CGRect
    ) -> CGFloat {
        let contentInset = column.isTabbed && projectedWindowCount > 1
            ? tabContentInset(for: column)
            : 0
        return max(1, workingFrame.width - contentInset)
    }

    private func setVerticalWindowWidth(
        _ window: NiriWindow,
        change: NiriSizeChange,
        in column: NiriContainer,
        projectedWindows: [NiriWindow],
        geometry: NiriSizingGeometry
    ) {
        if window.windowWidth.isAuto {
            NiriWindow.normalizeWidthWeights(in: projectedWindows)
        }

        let currentWindowPixels = window.currentWidthForSizing()
        let availableWidth = availableWindowWidth(
            in: column,
            projectedWindowCount: projectedWindows.count,
            workingFrame: geometry.workingFrame
        )
        let windowWidth = change.secondaryPixels(
            currentPixels: currentWindowPixels,
            availableSpan: availableWidth,
            gaps: geometry.gaps
        )

        column.applyWindowWidth(
            window,
            projectedWindows: projectedWindows,
            pixels: windowWidth,
            availableSpan: availableWidth,
            gaps: geometry.gaps
        )
    }

    func setWindowSecondarySpan(
        _ window: NiriWindow,
        change: NiriSizeChange,
        in workspaceId: WorkspaceDescriptor.ID,
        geometry: NiriSizingGeometry
    ) {
        assertSanctionedMutation()
        guard !isExcludedFromProjection(window.token, in: workspaceId),
              let column = findColumn(containing: window, in: workspaceId)
        else {
            return
        }
        let projectedWindows = projectedWindows(in: column, workspaceId: workspaceId)
        cancelInteractiveResize(for: column, in: workspaceId)
        if geometry.orientation == .vertical {
            setVerticalWindowWidth(
                window,
                change: change,
                in: column,
                projectedWindows: projectedWindows,
                geometry: geometry
            )
            return
        }

        if window.height.isAuto {
            NiriWindow.normalizeHeightWeights(in: projectedWindows)
        }

        let currentWindowPixels = window.currentHeightForSizing()
        let windowHeight = change.secondaryPixels(
            currentPixels: currentWindowPixels,
            availableSpan: geometry.workingFrame.height,
            gaps: geometry.gaps
        )

        column.applyWindowHeight(
            window,
            projectedWindows: projectedWindows,
            pixels: windowHeight,
            availableSpan: geometry.workingFrame.height,
            gaps: geometry.gaps
        )
    }

    func resetWindowSecondarySpan(
        _ window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID,
        orientation: Monitor.Orientation
    ) {
        assertSanctionedMutation()
        guard !isExcludedFromProjection(window.token, in: workspaceId),
              let column = findColumn(containing: window, in: workspaceId)
        else {
            return
        }
        let projectedWindows = projectedWindows(in: column, workspaceId: workspaceId)
        cancelInteractiveResize(for: column, in: workspaceId)
        if orientation == .vertical {
            if column.isTabbed {
                for tile in projectedWindows {
                    tile.windowWidth = .auto(weight: 1)
                }
            } else {
                window.windowWidth = .auto(weight: 1)
            }
            return
        }

        if column.isTabbed {
            for tile in projectedWindows {
                tile.height = .auto(weight: 1)
                tile.savedHeight = nil
            }
        } else {
            window.height = .auto(weight: 1)
            window.savedHeight = nil
        }
    }

    func toggleWindowSecondarySpan(
        _ window: NiriWindow,
        forwards: Bool,
        in workspaceId: WorkspaceDescriptor.ID,
        geometry: NiriSizingGeometry
    ) {
        assertSanctionedMutation()
        guard !presetWindowSecondarySpans.isEmpty else { return }
        guard !isExcludedFromProjection(window.token, in: workspaceId),
              let column = findColumn(containing: window, in: workspaceId)
        else {
            return
        }
        let projectedWindows = projectedWindows(in: column, workspaceId: workspaceId)
        cancelInteractiveResize(for: column, in: workspaceId)
        if geometry.orientation == .vertical {
            let availableWidth = availableWindowWidth(
                in: column,
                projectedWindowCount: projectedWindows.count,
                workingFrame: geometry.workingFrame
            )
            if window.windowWidth.isAuto {
                NiriWindow.normalizeWidthWeights(in: projectedWindows)
            }

            let nextIndex = window.nextSecondaryPresetIndex(
                forwards: forwards,
                presets: presetWindowSecondarySpans,
                availableSpan: availableWidth,
                gaps: geometry.gaps,
                orientation: geometry.orientation
            )

            window.windowWidth = .preset(nextIndex)
            if window.sizingMode == .maximized {
                window.sizingMode = .normal
            }
            return
        }

        if window.height.isAuto {
            NiriWindow.normalizeHeightWeights(in: projectedWindows)
        }

        let nextIdx = window.nextSecondaryPresetIndex(
            forwards: forwards,
            presets: presetWindowSecondarySpans,
            availableSpan: geometry.workingFrame.height,
            gaps: geometry.gaps,
            orientation: geometry.orientation
        )

        window.height = .preset(nextIdx)
        window.savedHeight = nil
        if window.sizingMode == .maximized {
            window.sizingMode = .normal
        }
    }
}
