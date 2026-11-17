// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct ColumnCentreCycle {
    static let nearPresetShare: CGFloat = 0.02

    let orientation: Monitor.Orientation
    let centre: CGFloat
    let columnIndex: Int?
    let followedPresetIndex: Int?
    var presetStop: Int?
    var spec: ProportionalSize
    var presetIndex: Int?
    var isFullSpan: Bool
    var span: ClosedRange<CGFloat>?

    func continues(
        _ column: NiriContainer, at index: Int?, span current: ClosedRange<CGFloat>, orientation: Monitor.Orientation
    ) -> Bool {
        guard self.orientation == orientation, let span,
              abs(span.lowerBound - current.lowerBound) < 2,
              abs(span.upperBound - current.upperBound) < 2
        else { return false }
        let horizontal = orientation == .horizontal
        return (horizontal ? column.width : column.height) == spec
            && (horizontal ? column.presetWidthIdx : nil) == presetIndex
            && (horizontal ? column.isFullWidth : column.isFullHeight) == isFullSpan && index == columnIndex
    }

    func nextPresetStop(forwards: Bool, presetCount: Int) -> Int {
        if let presetStop {
            return (presetStop + (forwards ? 1 : presetCount - 1)) % presetCount
        }
        guard let followedPresetIndex else { return forwards ? 0 : presetCount - 1 }
        return forwards ? (followedPresetIndex + 1) % presetCount : followedPresetIndex
    }
}

struct ColumnSpanBeforeFull: Equatable {
    let orientation: Monitor.Orientation
    let spec: ProportionalSize
    let presetIndex: Int?
    let hadManualSpan: Bool
    let centre: CGFloat?

    func restoreManualOverride(on column: NiriContainer) {
        if orientation == .horizontal {
            column.hasManualSingleWindowWidthOverride = hadManualSpan
        } else {
            column.hasManualSingleWindowHeightOverride = hadManualSpan
        }
    }
}

extension NiriLayoutEngine {
    @discardableResult
    func toggleColumnFullSpanAndBack(
        _ column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        let horizontal = context.orientation == .horizontal
        let spec = horizontal ? column.width : column.height
        let presetIndex = horizontal ? column.presetWidthIdx : nil
        let isFull = horizontal ? column.isFullWidth : column.isFullHeight
        let full = ProportionalSize.proportion(1)
        if let before = column.spanBeforeFull, before.orientation == context.orientation, spec == full,
           presetIndex == nil, !isFull
        {
            column.centreCycle = nil
            setContainerPrimarySpan(
                column,
                to: before.spec,
                presetIndex: before.presetIndex,
                context: context,
                state: &state
            )
            before.restoreManualOverride(on: column)
            if let centre = before.centre {
                centreAfterSpanToggle(column, on: centre, context: context, state: &state)
            }
            return true
        }
        let settled = horizontal ? column.settledWidth : column.settledHeight
        let pixels = settled > 0 ? settled : spanPixels(
            spec,
            for: column,
            context: context
        )
        guard !isFull, spec != full,
              pixels < spanPixels(full, for: column, context: context) - 1
        else { return false }
        let centre = settledScreenSpan(of: column, context: context, state: state)
            .map { ($0.lowerBound + $0.upperBound) / 2 }
        let before = ColumnSpanBeforeFull(
            orientation: context.orientation,
            spec: spec,
            presetIndex: presetIndex,
            hadManualSpan: horizontal
                ? column.hasManualSingleWindowWidthOverride : column.hasManualSingleWindowHeightOverride,
            centre: centre
        )
        column.centreCycle = nil
        setContainerPrimarySpan(column, to: full, presetIndex: nil, context: context, state: &state)
        column.spanBeforeFull = before
        if let centre {
            centreAfterSpanToggle(column, on: centre, context: context, state: &state)
        }
        return true
    }

    private func centreAfterSpanToggle(
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
    func cycleColumnSpanAroundCentre(
        _ column: NiriContainer,
        forwards: Bool = true,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        guard !presetContainerPrimarySpans.isEmpty,
              let before = settledScreenSpan(of: column, context: context, state: state)
        else {
            column.centreCycle = nil
            toggleContainerPrimarySpan(column, forwards: forwards, context: context, state: &state)
            return
        }
        let index = columnIndex(of: column, in: context.workspaceId)
        var cycle = column.centreCycle.flatMap { $0.continues(
            column,
            at: index,
            span: before,
            orientation: context.orientation
        ) ? $0 : nil }
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
        let horizontal = context.orientation == .horizontal
        cycle.spec = horizontal ? column.width : column.height
        cycle.presetIndex = horizontal ? column.presetWidthIdx : nil
        cycle.isFullSpan = horizontal ? column.isFullWidth : column.isFullHeight
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
        let horizontal = context.orientation == .horizontal
        let cached = horizontal ? column.cachedWidth : column.cachedHeight
        if horizontal { column.cachedWidth = column.settledWidth } else { column.cachedHeight = column.settledHeight }
        defer {
            if horizontal { column.cachedWidth = cached } else { column.cachedHeight = cached }
        }
        return columnScreenSpan(column, context: context, state: state)
    }

    private func startCentreCycle(
        _ column: NiriContainer,
        centre: CGFloat,
        index: Int?,
        _ context: NiriInteractionContext
    ) -> ColumnCentreCycle {
        let horizontal = context.orientation == .horizontal
        let settled = horizontal ? column.settledWidth : column.settledHeight
        let spec = horizontal ? column.width : column.height
        let isFull = horizontal ? column.isFullWidth : column.isFullHeight
        let pixels = settled > 0 ? settled : spanPixels(isFull ? .proportion(1) : spec, for: column, context: context)
        var nearest: Int?
        var nearestDistance = CGFloat.infinity
        var widestNarrower: Int?
        var widestSpan = -CGFloat.infinity
        for presetIndex in presetContainerPrimarySpans.indices {
            let span = spanPixels(presetSpec(presetIndex, for: column, context: context), for: column, context: context)
            let distance = abs(span - pixels)
            if distance < nearestDistance {
                nearest = presetIndex
                nearestDistance = distance
            }
            if span < pixels, span > widestSpan {
                widestNarrower = presetIndex
                widestSpan = span
            }
        }
        return ColumnCentreCycle(
            orientation: context.orientation,
            centre: centre,
            columnIndex: index,
            followedPresetIndex: widestNarrower,
            presetStop: nearestDistance <= context.primarySpan * ColumnCentreCycle.nearPresetShare ? nearest : nil,
            spec: spec,
            presetIndex: horizontal ? column.presetWidthIdx : nil,
            isFullSpan: isFull,
            span: nil
        )
    }

    private func presetSpec(
        _ presetIndex: Int,
        for column: NiriContainer,
        context: NiriInteractionContext
    ) -> ProportionalSize {
        NiriSizeChange(presetContainerPrimarySpans[presetIndex]).primarySpanSpec(
            currentPixels: context.orientation == .horizontal ? column.settledWidth : column.settledHeight,
            axisSpan: context.primarySpan,
            gaps: context.gaps
        )
    }

    private func spanPixels(
        _ spec: ProportionalSize,
        for column: NiriContainer,
        context: NiriInteractionContext
    ) -> CGFloat {
        column.resolvedPrimarySpan(
            spec,
            orientation: context.orientation,
            availableSpace: context.primarySpan,
            gaps: context.gaps,
            contentInset: context.orientation == .horizontal ? tabContentInset(for: column) : 0
        )
    }
}
