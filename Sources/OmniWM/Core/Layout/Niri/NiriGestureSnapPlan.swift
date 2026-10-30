// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct NiriGestureSnapPlan {
    struct Point {
        let viewPos: Double
        let columnIndex: Int
        var isOverscrollBoundary = false
    }

    struct Geometry {
        let areas: ViewportFittingAreas
        let gap: CGFloat
        let gaps: Double
        let viewSpan: Double
        let sizeKeyPath: KeyPath<NiriContainer, CGFloat>
        let isCentering: Bool
        let viewport: NiriViewportGeometry
        private let centerOnOverflow: Bool

        init(
            viewport: NiriViewportGeometry,
            centerMode: CenterFocusedColumn,
            alwaysCenterSingleColumn: Bool,
            columnCount: Int
        ) {
            let areas = ViewportFittingAreas(geometry: viewport)
            self.areas = areas
            self.viewport = viewport
            gap = viewport.gap
            isCentering = centerMode == .always || (alwaysCenterSingleColumn && columnCount <= 1)
            viewSpan = Double(areas.viewSpan)
            gaps = Double(viewport.gap)
            sizeKeyPath = areas.orientation.renderedSpanKeyPath
            centerOnOverflow = centerMode == .onOverflow
        }

        func snapPair(
            containerPosition: Double,
            column: NiriContainer,
            previousContainerSpan: Double?,
            nextContainerSpan: Double?
        ) -> (leading: Double, trailing: Double) {
            let containerSpan = Double(column[keyPath: sizeKeyPath])
            let mode = column.effectiveSizingMode

            if mode.isFullscreen {
                return (containerPosition, containerPosition + containerSpan)
            }

            let area = areas.area(for: mode)
            let areaSpan = Double(areas.span(of: area))
            let leadingStrut = Double(areas.origin(of: area))
            let trailingStrut = viewSpan - areaSpan - leadingStrut
            let padding = mode.isMaximized ? 0 : ((areaSpan - containerSpan) / 2.0).clamped(to: 0 ... gaps)
            let center = if areaSpan <= containerSpan {
                containerPosition - leadingStrut
            } else {
                containerPosition - (areaSpan - containerSpan) / 2.0 - leadingStrut
            }

            let leading = isOverflowing(nextContainerSpan, containerSpan: containerSpan, areaSpan: areaSpan)
                ? center
                : containerPosition - padding - leadingStrut
            let trailing = isOverflowing(previousContainerSpan, containerSpan: containerSpan, areaSpan: areaSpan)
                ? center + viewSpan
                : containerPosition + containerSpan + padding + trailingStrut
            return (leading, trailing)
        }

        private func isOverflowing(_ adjacentSpan: Double?, containerSpan: Double, areaSpan: Double) -> Bool {
            guard centerOnOverflow, let adjacentSpan else { return false }
            return adjacentSpan + 3.0 * gaps + containerSpan > areaSpan
        }
    }

    let geometry: Geometry
    private var points: [Point] = []

    init(geometry: Geometry) {
        self.geometry = geometry
    }

    mutating func appendCenteredPoints(in columns: [NiriContainer]) {
        var containerPosition = 0.0
        for (idx, col) in columns.enumerated() {
            let containerSpan = Double(col[keyPath: geometry.sizeKeyPath])
            let mode = col.effectiveSizingMode
            let area = geometry.areas.area(for: mode)
            let areaSpan = Double(geometry.areas.span(of: area))
            let leadingStrut = Double(geometry.areas.origin(of: area))

            let viewPos: Double
            if mode.isFullscreen {
                viewPos = containerPosition
            } else if areaSpan <= containerSpan {
                viewPos = containerPosition - leadingStrut
            } else {
                viewPos = containerPosition - (areaSpan - containerSpan) / 2.0 - leadingStrut
            }
            appendPoint(viewPos, columnIndex: idx)

            containerPosition += containerSpan + geometry.gaps
        }
    }

    mutating func appendBoundedPoints(in columns: [NiriContainer], bounds: (leading: Double, trailing: Double)) {
        var containerPosition = 0.0
        for (idx, col) in columns.enumerated() {
            let pair = geometry.snapPair(
                containerPosition: containerPosition,
                column: col,
                previousContainerSpan: idx > 0
                    ? Double(columns[idx - 1][keyPath: geometry.sizeKeyPath])
                    : nil,
                nextContainerSpan: idx + 1 < columns.count
                    ? Double(columns[idx + 1][keyPath: geometry.sizeKeyPath])
                    : nil
            )
            appendPair(pair, columnIndex: idx, bounds: bounds)

            containerPosition += Double(col[keyPath: geometry.sizeKeyPath]) + geometry.gaps
        }
    }

    private mutating func appendPair(
        _ pair: (leading: Double, trailing: Double),
        columnIndex: Int,
        bounds: (leading: Double, trailing: Double)
    ) {
        if bounds.leading < pair.leading, pair.leading < bounds.trailing {
            appendPoint(pair.leading, columnIndex: columnIndex)
        }

        let trailingViewPos = pair.trailing - geometry.viewSpan
        if bounds.leading < trailingViewPos, trailingViewPos < bounds.trailing {
            appendPoint(trailingViewPos, columnIndex: columnIndex)
        }
    }

    mutating func appendPoint(_ viewPos: Double, columnIndex: Int, isOverscrollBoundary: Bool = false) {
        guard viewPos.isFinite else { return }
        points.append(Point(
            viewPos: viewPos, columnIndex: columnIndex, isOverscrollBoundary: isOverscrollBoundary
        ))
    }

    mutating func closestPoint(to projectedViewPos: Double) -> Point? {
        points.sort { $0.viewPos < $1.viewPos }
        return points.min(by: { abs($0.viewPos - projectedViewPos) < abs($1.viewPos - projectedViewPos) })
    }
}
