// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct NiriGestureMomentumPlan {
    struct Landing {
        let finalOffset: Double
        let normalizedActiveColumn: Int
    }

    private let positions: [Double]
    private let viewportSpan: Double
    private let viewStartBounds: ClosedRange<Double>
    private let sizeKeyPath: KeyPath<NiriContainer, CGFloat>

    init?(
        columns: [NiriContainer],
        gap: CGFloat,
        viewportSpan: Double,
        totalContentSpan: Double,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
        viewStartBounds: ClosedRange<Double>? = nil
    ) {
        guard !columns.isEmpty,
              totalContentSpan.isFinite,
              totalContentSpan > 0,
              viewportSpan.isFinite,
              viewportSpan > 0
        else {
            return nil
        }

        let gap = Double(gap)
        var positions: [Double] = []
        positions.reserveCapacity(columns.count)
        var runningPosition = 0.0
        for column in columns {
            positions.append(runningPosition)
            runningPosition += Double(column[keyPath: sizeKeyPath]) + gap
        }
        self.positions = positions
        self.viewportSpan = viewportSpan
        self.viewStartBounds = viewStartBounds ?? (0 ... max(0, totalContentSpan - viewportSpan))
        self.sizeKeyPath = sizeKeyPath
    }

    func landing(columns: [NiriContainer], activeIndex: Int, currentOffset: Double) -> Landing {
        let previousActiveColumn = activeIndex.clamped(to: 0 ... columns.count - 1)
        let previousActivePosition = positions[previousActiveColumn]
        let rawViewStart = previousActivePosition + currentOffset
        let viewStart = rawViewStart.clamped(to: viewStartBounds)
        let viewEnd = viewStart + viewportSpan

        let currentContainerSpan = max(0, Double(columns[previousActiveColumn][keyPath: sizeKeyPath]))
        let currentColumnOverlap = visibleOverlap(
            start: previousActivePosition,
            end: previousActivePosition + currentContainerSpan,
            viewStart: viewStart,
            viewEnd: viewEnd
        )
        let normalizedActiveColumn: Int
        if currentContainerSpan > 0, currentColumnOverlap + 0.001 >= currentContainerSpan / 2.0 {
            normalizedActiveColumn = previousActiveColumn
        } else {
            normalizedActiveColumn = bestVisibleColumn(
                columns: columns,
                previousActiveColumn: previousActiveColumn,
                viewStart: viewStart,
                viewEnd: viewEnd
            )
        }

        let normalizedActivePosition = positions[normalizedActiveColumn]
        return Landing(
            finalOffset: viewStart - normalizedActivePosition,
            normalizedActiveColumn: normalizedActiveColumn
        )
    }

    private func bestVisibleColumn(
        columns: [NiriContainer],
        previousActiveColumn: Int,
        viewStart: Double,
        viewEnd: Double
    ) -> Int {
        let viewportCenter = viewStart + viewportSpan / 2.0
        var bestIndex = previousActiveColumn
        var bestOverlap = -Double.infinity
        var bestCenterDistance = Double.infinity

        for (index, column) in columns.enumerated() {
            let columnStart = positions[index]
            let columnSpan = max(0, Double(column[keyPath: sizeKeyPath]))
            let columnEnd = columnStart + columnSpan
            let overlap = visibleOverlap(
                start: columnStart,
                end: columnEnd,
                viewStart: viewStart,
                viewEnd: viewEnd
            )
            let centerDistance = abs((columnStart + columnEnd) / 2.0 - viewportCenter)

            if overlap > bestOverlap + 0.001 ||
                (abs(overlap - bestOverlap) <= 0.001 && centerDistance < bestCenterDistance)
            {
                bestIndex = index
                bestOverlap = overlap
                bestCenterDistance = centerDistance
            }
        }
        return bestIndex
    }

    private func visibleOverlap(
        start: Double,
        end: Double,
        viewStart: Double,
        viewEnd: Double
    ) -> Double {
        max(0, min(end, viewEnd) - max(start, viewStart))
    }
}
