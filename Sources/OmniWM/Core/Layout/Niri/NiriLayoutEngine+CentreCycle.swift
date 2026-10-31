// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct ColumnCentreCycle {
    enum Stop: Equatable {
        case start
        case preset(Int)
    }

    let startWidth: ProportionalSize
    let startPresetIndex: Int?
    let startIsFullWidth: Bool
    let startPixels: CGFloat
    let centre: CGFloat
    let columnIndex: Int?
    var stop: Stop
    var width: ProportionalSize
    var presetIndex: Int?
    var isFullWidth: Bool

    func continues(_ column: NiriContainer, at index: Int?) -> Bool {
        column.width == width && column.presetWidthIdx == presetIndex
            && column.isFullWidth == isFullWidth && index == columnIndex
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
              let before = columnScreenSpan(column, context: context, state: state)
        else {
            column.centreCycle = nil
            toggleContainerPrimarySpan(column, forwards: forwards, context: context, state: &state)
            return
        }
        let index = columnIndex(of: column, in: context.workspaceId)
        var cycle = column.centreCycle.flatMap { $0.continues(column, at: index) ? $0 : nil }
            ?? startCentreCycle(column, centre: (before.lowerBound + before.upperBound) / 2, index: index, context)
        let stops = centreCycleStops(column, cycle: cycle, context: context)
        guard let current = stops.firstIndex(of: cycle.stop) else { return }
        let next = stops[(current + (forwards ? 1 : stops.count - 1)) % stops.count]
        applyCentreCycleStop(next, of: cycle, to: column, context: context, state: &state)
        cycle.stop = next
        cycle.width = column.width
        cycle.presetIndex = column.presetWidthIdx
        cycle.isFullWidth = column.isFullWidth
        column.centreCycle = cycle
        guard !(isViewportAnchor(column, in: context.workspaceId, state: state)
            && centresFocusedColumn(in: context.workspaceId))
        else { return }
        centreColumn(column, on: cycle.centre, animated: true, context: context, state: &state)
    }

    private func applyCentreCycleStop(
        _ stop: ColumnCentreCycle.Stop,
        of cycle: ColumnCentreCycle,
        to column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        switch stop {
        case .start:
            setContainerPrimarySpan(
                column,
                to: cycle.startIsFullWidth ? .proportion(1) : cycle.startWidth,
                presetIndex: cycle.startPresetIndex,
                context: context,
                state: &state
            )
            if cycle.startIsFullWidth {
                column.width = cycle.startWidth
                column.isFullWidth = true
            }
        case let .preset(presetIndex):
            setContainerPrimarySpan(
                column,
                to: presetSpec(presetIndex, for: column, context: context),
                presetIndex: presetIndex,
                context: context,
                state: &state
            )
        }
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
        let matching = presetContainerPrimarySpans.indices.first { presetIndex in
            abs(widthPixels(presetSpec(presetIndex, for: column, context: context), for: column, context: context)
                - pixels) < 1
        }
        return ColumnCentreCycle(
            startWidth: column.width,
            startPresetIndex: column.presetWidthIdx,
            startIsFullWidth: column.isFullWidth,
            startPixels: pixels,
            centre: centre,
            columnIndex: index,
            stop: matching.map { .preset($0) } ?? .start,
            width: column.width,
            presetIndex: column.presetWidthIdx,
            isFullWidth: column.isFullWidth
        )
    }

    private func centreCycleStops(
        _ column: NiriContainer,
        cycle: ColumnCentreCycle,
        context: NiriInteractionContext
    ) -> [ColumnCentreCycle.Stop] {
        var stops = presetContainerPrimarySpans.indices.map { presetIndex in
            (
                stop: ColumnCentreCycle.Stop.preset(presetIndex),
                pixels: widthPixels(
                    presetSpec(presetIndex, for: column, context: context),
                    for: column,
                    context: context
                )
            )
        }
        if cycle.stop == .start || !stops.contains(where: { abs($0.pixels - cycle.startPixels) < 1 }) {
            stops.append((stop: .start, pixels: cycle.startPixels))
        }
        return stops.enumerated()
            .sorted { ($0.element.pixels, $0.offset) < ($1.element.pixels, $1.offset) }
            .map(\.element.stop)
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
