// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct NiriOverviewTileSnapshot: Equatable {
    let token: WindowToken
    let preferredHeight: CGFloat
    var stripFrame: CGRect?
    var isViewportAnchored = false
}

struct NiriOverviewColumnSnapshot: Equatable {
    let index: Int
    let widthWeight: CGFloat
    let preferredWidth: CGFloat?
    let tiles: [NiriOverviewTileSnapshot]
    var stripFrame: CGRect?
    var isTabbed = false
    var activeToken: WindowToken?
}

struct NiriOverviewStripGeometry: Equatable {
    let workingFrame: CGRect
    let secondaryGap: CGFloat
    var orientation: Monitor.Orientation = .horizontal
    var viewportPosition: CGFloat = 0
}

struct NiriOverviewWorkspaceSnapshot: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let columns: [NiriOverviewColumnSnapshot]
    var strip: NiriOverviewStripGeometry?
}

extension NiriLayoutEngine {
    func overviewSnapshot(
        for workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        geometry: NiriLayoutGeometry
    ) -> NiriOverviewWorkspaceSnapshot? {
        assertSanctionedMutation()
        let columns = projectedColumns(in: workspaceId)
        guard !columns.isEmpty else { return nil }
        let context = NiriCalculationContext(
            geometry: geometry, time: 0,
            hiddenPlacementMonitor: nil, hiddenPlacementMonitors: []
        )
        reconcilePrimarySpanFit(
            in: workspaceId, workingFrame: context.area.workingFrame,
            gaps: context.primaryGap, orientation: context.orientation, motion: nil
        )
        let snapshots: [NiriOverviewColumnSnapshot]
        let viewportPosition: CGFloat
        if let single = singleWindowLayoutContext(in: workspaceId), let column = columns.first {
            snapshots = [overviewSingleColumn(column, single: single, context: context)]
            viewportPosition = 0
        } else {
            let prepared = prepareLayoutColumns(
                columns, area: context.area, primaryGap: context.primaryGap,
                time: context.time, orientation: context.orientation
            )
            let activeIndex = projectedActiveColumnIndex(state: state, columns: columns, in: workspaceId)
            viewportPosition = prepared[activeIndex].position + state.viewOffset
            snapshots = columns.enumerated().map { index, column in
                let preparedColumn = prepared[index]
                let rect = context.area.canonicalContainerRect(
                    position: preparedColumn.position, span: preparedColumn.span, orientation: context.orientation
                )
                return overviewColumn(
                    column,
                    placement: NiriContainerPlacement(
                        canonicalRect: rect,
                        renderedRect: rect,
                        secondarySpanOverride: nil
                    ),
                    context: context, viewPosition: viewportPosition
                )
            }
        }
        return NiriOverviewWorkspaceSnapshot(
            workspaceId: workspaceId, columns: snapshots,
            strip: NiriOverviewStripGeometry(
                workingFrame: context.area.workingFrame.offsetBy(
                    dx: -context.area.viewFrame.minX, dy: -context.area.viewFrame.minY
                ),
                secondaryGap: context.secondaryGap, orientation: context.orientation,
                viewportPosition: viewportPosition
            )
        )
    }

    private func overviewSingleColumn(
        _ column: NiriProjectedColumn,
        single: SingleWindowLayoutContext,
        context: NiriCalculationContext
    ) -> NiriOverviewColumnSnapshot {
        let rect = resolvedSingleWindowRect(
            for: single, in: context.area.singleWindowFrame,
            borderSafeFillFrame: context.area.borderSafeFillFrame,
            fullscreenLayoutFrame: context.area.fullscreenLayoutFrame,
            scale: context.area.scale, gaps: context.geometry.gaps, orientation: context.orientation
        )
        return overviewColumn(
            column,
            placement: single.layoutPlacement(
                for: rect, workspaceOffset: 0, scale: context.area.scale,
                time: context.time, orientation: context.orientation
            ),
            context: context, viewPosition: 0, isSingleWindowFit: true
        )
    }

    private func overviewColumn(
        _ column: NiriProjectedColumn,
        placement: NiriContainerPlacement,
        context: NiriCalculationContext,
        viewPosition: CGFloat,
        isSingleWindowFit: Bool = false
    ) -> NiriOverviewColumnSnapshot {
        let isTabbed = column.column.isTabbed && column.windows.count > 1
        let frames = NiriContainerLayoutFrames(
            canonicalRect: placement.canonicalRect, renderedRect: placement.canonicalRect,
            tabOffset: isTabbed ? renderStyle.tabIndicatorWidth : 0, layoutFrames: context.frames
        )
        let secondaryGap = isSingleWindowFit ? 0 : context.secondaryGap
        let spans = resolveWindowSpans(
            container: column.column, windows: column.windows,
            axis: NiriAxisLayout(
                availableSpace: frames.secondarySpan(), gap: secondaryGap,
                isTabbed: isTabbed, orientation: context.orientation
            ),
            secondarySpanOverride: placement.secondarySpanOverride
        )
        var position = frames.secondaryStart(gap: secondaryGap)
        let tiles = column.windows.enumerated().map { index, window in
            let layout = frames.windowLayout(
                for: window.sizingMode, position: position, span: spans[index].value, layoutFrames: context.frames
            )
            if !isTabbed { position += spans[index].value + secondaryGap }
            let isViewportAnchored = isSingleWindowFit || window.sizingMode != .normal
            return NiriOverviewTileSnapshot(
                token: window.token, preferredHeight: layout.frame.height,
                stripFrame: overviewLocalFrame(
                    layout.frame, context: context, viewPosition: isViewportAnchored ? 0 : viewPosition
                ),
                isViewportAnchored: isViewportAnchored
            )
        }
        return NiriOverviewColumnSnapshot(
            index: column.durableIndex, widthWeight: 1, preferredWidth: placement.canonicalRect.width,
            tiles: tiles.reversed(),
            stripFrame: overviewLocalFrame(placement.canonicalRect, context: context, viewPosition: viewPosition),
            isTabbed: isTabbed, activeToken: projectedActiveWindow(in: column)?.token
        )
    }

    private func overviewLocalFrame(
        _ frame: CGRect,
        context: NiriCalculationContext,
        viewPosition: CGFloat
    ) -> CGRect {
        context.area.visibleRenderedContainerRect(
            canonicalRect: frame, viewPosition: viewPosition,
            workspaceOffset: 0, renderOffset: .zero, orientation: context.orientation
        ).offsetBy(dx: -context.area.viewFrame.minX, dy: -context.area.viewFrame.minY)
    }
}
