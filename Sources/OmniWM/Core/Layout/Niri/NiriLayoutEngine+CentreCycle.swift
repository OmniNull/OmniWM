// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct ColumnCentreCycle {
    static let nearPresetShare: CGFloat = 0.02

    let centre: CGFloat
    let columnIndex: Int?
    let followedPresetIndex: Int?
    var presetStop: Int?
    var width: ProportionalSize
    var presetIndex: Int?
    var isFullWidth: Bool
    var span: ClosedRange<CGFloat>?

    func continues(_ column: NiriContainer, at index: Int?, span current: ClosedRange<CGFloat>) -> Bool {
        guard let span,
              abs(span.lowerBound - current.lowerBound) < 2,
              abs(span.upperBound - current.upperBound) < 2
        else { return false }
        return column.width == width && column.presetWidthIdx == presetIndex
            && column.isFullWidth == isFullWidth && index == columnIndex
    }

    func nextPresetStop(forwards: Bool, presetCount: Int) -> Int {
        if let presetStop {
            return (presetStop + (forwards ? 1 : presetCount - 1)) % presetCount
        }
        guard let followedPresetIndex else { return forwards ? 0 : presetCount - 1 }
        return forwards ? (followedPresetIndex + 1) % presetCount : followedPresetIndex
    }
}

struct ColumnWidthBeforeFull: Equatable {
    let width: ProportionalSize
    let presetIndex: Int?
    let hadManualWidth: Bool
    let centre: CGFloat?
}

extension NiriLayoutEngine {
    @discardableResult
    func toggleColumnFullWidthAndBack(
        _ column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        guard context.orientation == .horizontal else { return false }
        let full = ProportionalSize.proportion(1)
        if let before = column.widthBeforeFull, column.width == full, column.presetWidthIdx == nil,
           !column.isFullWidth
        {
            column.centreCycle = nil
            setContainerPrimarySpan(
                column,
                to: before.width,
                presetIndex: before.presetIndex,
                context: context,
                state: &state
            )
            column.hasManualSingleWindowWidthOverride = before.hadManualWidth
            if let centre = before.centre {
                centreAfterWidthToggle(column, on: centre, context: context, state: &state)
            }
            return true
        }
        let pixels = column.settledWidth > 0 ? column.settledWidth : widthPixels(
            column.width,
            for: column,
            context: context
        )
        guard !column.isFullWidth, column.width != full,
              pixels < widthPixels(full, for: column, context: context) - 1
        else { return false }
        let centre = settledScreenSpan(of: column, context: context, state: state)
            .map { ($0.lowerBound + $0.upperBound) / 2 }
        let before = ColumnWidthBeforeFull(
            width: column.width,
            presetIndex: column.presetWidthIdx,
            hadManualWidth: column.hasManualSingleWindowWidthOverride,
            centre: centre
        )
        column.centreCycle = nil
        setContainerPrimarySpan(column, to: full, presetIndex: nil, context: context, state: &state)
        column.widthBeforeFull = before
        if let centre {
            centreAfterWidthToggle(column, on: centre, context: context, state: &state)
        }
        return true
    }

    private func centreAfterWidthToggle(
        _ column: NiriContainer,
        on centre: CGFloat,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        guard !(isViewportAnchor(column, in: context.workspaceId, state: state)
            && centresFocusedColumn(in: context.workspaceId))
        else { return }
        centreColumn(column, on: centre, animated: true, context: context, state: &state)
    }
}

extension NiriLayoutEngine {
    func cycleColumnWidthAroundCentre(
        _ column: NiriContainer,
        forwards: Bool = true,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        guard context.orientation == .horizontal,
              !presetContainerPrimarySpans.isEmpty,
              let before = settledScreenSpan(of: column, context: context, state: state)
        else {
            column.centreCycle = nil
            toggleContainerPrimarySpan(column, forwards: forwards, context: context, state: &state)
            return
        }
        let index = columnIndex(of: column, in: context.workspaceId)
        var cycle = column.centreCycle.flatMap { $0.continues(column, at: index, span: before) ? $0 : nil }
            ?? startCentreCycle(column, centre: (before.lowerBound + before.upperBound) / 2, index: index, context)
        let next = cycle.nextPresetStop(forwards: forwards, presetCount: presetContainerPrimarySpans.count)
        setContainerPrimarySpan(
            column,
            to: presetSpec(next, for: column, context: context),
            presetIndex: next,
            context: context,
            state: &state
        )
        cycle.presetStop = next
        cycle.width = column.width
        cycle.presetIndex = column.presetWidthIdx
        cycle.isFullWidth = column.isFullWidth
        if !(isViewportAnchor(column, in: context.workspaceId, state: state)
            && centresFocusedColumn(in: context.workspaceId))
        {
            centreColumn(column, on: cycle.centre, animated: true, context: context, state: &state)
        }
        cycle.span = settledScreenSpan(of: column, context: context, state: state)
        column.centreCycle = cycle
    }

    private func settledScreenSpan(
        of column: NiriContainer,
        context: NiriInteractionContext,
        state: ViewportState
    ) -> ClosedRange<CGFloat>? {
        let width = column.cachedWidth
        column.cachedWidth = column.settledWidth
        defer { column.cachedWidth = width }
        return columnScreenSpan(column, context: context, state: state)
    }

    private func startCentreCycle(
        _ column: NiriContainer,
        centre: CGFloat,
        index: Int?,
        _ context: NiriInteractionContext
    ) -> ColumnCentreCycle {
        let pixels = column.settledWidth > 0
            ? column.settledWidth
            : widthPixels(column.isFullWidth ? .proportion(1) : column.width, for: column, context: context)
        let presetPixels = presetContainerPrimarySpans.indices.map { presetIndex in
            widthPixels(presetSpec(presetIndex, for: column, context: context), for: column, context: context)
        }
        let nearest = presetPixels.indices.min { abs(presetPixels[$0] - pixels) < abs(presetPixels[$1] - pixels) }
        let isNear = nearest.map {
            abs(presetPixels[$0] - pixels) <= context.workingFrame.width * ColumnCentreCycle.nearPresetShare
        } ?? false
        let widestNarrower = presetPixels.indices
            .filter { presetPixels[$0] < pixels }
            .max { presetPixels[$0] < presetPixels[$1] }
        return ColumnCentreCycle(
            centre: centre,
            columnIndex: index,
            followedPresetIndex: widestNarrower,
            presetStop: isNear ? nearest : nil,
            width: column.width,
            presetIndex: column.presetWidthIdx,
            isFullWidth: column.isFullWidth,
            span: nil
        )
    }

    private func presetSpec(
        _ presetIndex: Int,
        for column: NiriContainer,
        context: NiriInteractionContext
    ) -> ProportionalSize {
        NiriSizeChange(presetContainerPrimarySpans[presetIndex]).primarySpanSpec(
            currentPixels: column.settledWidth,
            axisSpan: context.workingFrame.width,
            gaps: context.gaps
        )
    }

    private func widthPixels(
        _ width: ProportionalSize,
        for column: NiriContainer,
        context: NiriInteractionContext
    ) -> CGFloat {
        column.resolvedWidthPixels(
            width,
            availableSpan: context.workingFrame.width,
            gaps: context.gaps,
            contentInset: tabContentInset(for: column)
        )
    }
}
