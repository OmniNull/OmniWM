// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func layoutSingleWindow(
        _ single: SingleWindowLayoutContext,
        context: NiriCalculationContext,
        result: inout LayoutResult
    ) {
        let layoutArea = context.area
        let orientation = context.orientation
        let time = context.time
        let canonicalRect = resolvedSingleWindowRect(
            for: single,
            in: layoutArea.singleWindowFrame,
            borderSafeFillFrame: layoutArea.borderSafeFillFrame,
            fullscreenLayoutFrame: layoutArea.fullscreenLayoutFrame,
            scale: layoutArea.scale,
            gaps: context.geometry.gaps,
            orientation: orientation
        )
        let placement = single.layoutPlacement(
            for: canonicalRect,
            workspaceOffset: 0,
            scale: layoutArea.scale,
            time: time,
            orientation: orientation
        )
        layoutContainer(
            container: single.container,
            windows: [single.window],
            placement: placement,
            context: NiriContainerLayoutContext(frames: context.frames, secondaryGap: 0, time: time),
            result: &result.frames
        )
    }

    func columnLayoutPass(
        selection: NiriViewportSelection,
        columns: [NiriProjectedColumn],
        prepared: borrowing [NiriPreparedLayoutColumn],
        context: NiriCalculationContext,
        sampling: NiriViewportSampling
    ) -> NiriColumnLayoutPass {
        let activeIndex = projectedActiveColumnIndex(
            state: selection.state,
            columns: columns,
            in: selection.workspaceId
        )
        let activeColumn = prepared[activeIndex]
        let activePosition = activeColumn.position
        let viewPosition = activePosition + sampling.viewOffset
        let viewPositions = sampling.settledVisibilityOffset
            .map { [activePosition + $0, viewPosition] } ?? [viewPosition]
        let revealMargin: CGFloat = switch context.orientation {
        case .horizontal: context.area.workingFrame.width * 0.25
        case .vertical: context.area.workingFrame.height * 0.25
        }
        return NiriColumnLayoutPass(
            context: context,
            viewport: NiriLayoutViewport(
                area: context.area, orientation: context.orientation, workspaceOffset: 0,
                viewPositions: viewPositions, revealMargin: revealMargin
            ),
            activeIndex: activeIndex,
            viewPosition: viewPosition,
            selectedNodeId: selection.state.selectedNodeId,
            settledContentFrame: sampling.isSettled
                ? settledContentFrame(context: context, activeSpan: activeColumn.span) : nil
        )
    }

    private func settledContentFrame(context: NiriCalculationContext, activeSpan: CGFloat) -> CGRect {
        let area = context.area.workingFrame
        switch context.orientation {
        case .horizontal:
            return area.insetBy(
                dx: settledContentInset(viewportSpan: area.width, activeSpan: activeSpan, gap: context.primaryGap),
                dy: 0
            )
        case .vertical:
            return area.insetBy(
                dx: 0,
                dy: settledContentInset(viewportSpan: area.height, activeSpan: activeSpan, gap: context.primaryGap)
            )
        }
    }

    func settledContentInset(viewportSpan: CGFloat, activeSpan: CGFloat, gap: CGFloat) -> CGFloat {
        ((viewportSpan - activeSpan) / 2).clamped(to: 0 ... gap)
    }

    func layoutProjectedColumn(
        _ column: NiriProjectedColumn,
        prepared: NiriPreparedLayoutColumn,
        at index: Int,
        pass: NiriColumnLayoutPass,
        result: inout LayoutResult
    ) {
        let visibility = pass.viewport.columnVisibility(
            for: prepared, at: index, viewPosition: pass.viewPosition,
            hiddenPlacementMonitor: pass.context.hiddenPlacementMonitor,
            hiddenPlacementMonitors: pass.context.hiddenPlacementMonitors
        )
        let renderedRect = renderedColumnFrame(column, at: index, visibility: visibility, pass: pass, result: &result)
        layoutContainer(
            container: column.column,
            windows: column.windows,
            placement: NiriContainerPlacement(
                canonicalRect: visibility.canonicalRect,
                renderedRect: renderedRect,
                secondarySpanOverride: nil
            ),
            context: NiriContainerLayoutContext(
                frames: pass.context.frames,
                secondaryGap: pass.context.secondaryGap,
                time: pass.context.time
            ),
            result: &result.frames
        )
    }

    private func renderedColumnFrame(
        _ projectedColumn: NiriProjectedColumn,
        at idx: Int,
        visibility: NiriColumnVisibility,
        pass: NiriColumnLayoutPass,
        result: inout LayoutResult
    ) -> CGRect {
        let layoutArea = pass.context.area
        let orientation = pass.context.orientation
        let visibilityRect = visibility.visibleRect
        let renderedContainerRect: CGRect
        switch visibility.state {
        case .visible:
            if let settledContentFrame = pass.settledContentFrame,
               idx != pass.activeIndex,
               projectedColumn.windows.allSatisfy({ $0.sizingMode == .normal && $0.id != pass.selectedNodeId })
            {
                renderedContainerRect = layoutArea.settledRenderedContainerRect(
                    visibilityRect,
                    contentFrame: settledContentFrame,
                    orientation: orientation
                )
            } else {
                renderedContainerRect = visibilityRect
            }
            if projectedColumn.column.isTabbed, projectedColumn.windows.count > 1 {
                let parkEdge = layoutArea.hiddenEdge(
                    for: visibilityRect,
                    fallback: idx == 0 ? .minimum : .maximum,
                    orientation: orientation
                )
                let activeWindow = projectedActiveWindow(in: projectedColumn)
                for window in projectedColumn.windows where window !== activeWindow {
                    result.hiddenHandles[window.token] = parkEdge.encodedHideSide
                }
            }
        case let .hidden(hiddenEdge):
            for window in projectedColumn.windows {
                result.hiddenHandles[window.token] = hiddenEdge.encodedHideSide
            }
            renderedContainerRect = layoutArea.hiddenRenderedContainerRect(
                canonicalRect: visibility.canonicalRect,
                edge: hiddenEdge,
                orientation: orientation,
                hiddenPlacementMonitor: pass.context.hiddenPlacementMonitor,
                hiddenPlacementMonitors: pass.context.hiddenPlacementMonitors
            )
        }
        return renderedContainerRect
    }
}
