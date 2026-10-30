// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension ViewportState {
    mutating func endGesture(
        currentOffset: Double,
        projectedOffset: Double,
        columns: [NiriContainer],
        geometry: NiriViewportGeometry,
        motion: MotionSnapshot,
        snapToColumn: Bool = true,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) {
        guard !columns.isEmpty else {
            endGestureWithoutSnap(currentOffset: currentOffset)
            return
        }

        let sizeKeyPath = geometry.orientation.renderedSpanKeyPath
        let totalContentSpan = Double(totalSpan(containers: columns, gap: geometry.gap, sizeKeyPath: sizeKeyPath))
        guard totalContentSpan.isFinite, totalContentSpan > 0 else {
            endGestureWithoutSnap(currentOffset: currentOffset)
            return
        }

        guard snapToColumn else {
            endGestureWithMomentum(
                projectedOffset: projectedOffset,
                columns: columns,
                geometry: geometry,
                totalContentSpan: totalContentSpan,
                motion: motion
            )
            return
        }

        let activeContainerPosition = containerPosition(
            at: activeColumnIndex,
            containers: columns,
            gap: geometry.gap,
            sizeKeyPath: sizeKeyPath
        )
        let projectedViewPos = Double(activeContainerPosition) + projectedOffset
        let snapGeometry = NiriGestureSnapPlan.Geometry(
            viewport: geometry,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            columnCount: columns.count
        )

        let result = findSnapPointsAndTarget(
            projectedViewPos: projectedViewPos,
            projectedOffset: projectedOffset,
            currentOffset: currentOffset,
            columns: columns,
            plan: NiriGestureSnapPlan(geometry: snapGeometry)
        )

        applyGestureSnap(
            result: result,
            columns: columns,
            previousPosition: activeContainerPosition,
            geometry: snapGeometry,
            motion: motion
        )
    }

    private mutating func applyGestureSnap(
        result: NiriGestureSnapPlan.Point,
        columns: [NiriContainer],
        previousPosition: CGFloat,
        geometry: NiriGestureSnapPlan.Geometry,
        motion: MotionSnapshot
    ) {
        let newContainerPosition = containerPosition(
            at: result.columnIndex,
            containers: columns,
            gap: geometry.gap,
            sizeKeyPath: geometry.sizeKeyPath
        )
        let offsetDelta = previousPosition - newContainerPosition

        let previousActiveColumnIndex = activeColumnIndex
        activeColumnIndex = result.columnIndex
        if previousActiveColumnIndex != result.columnIndex {
            viewOffsetToRestore = nil
        }

        let snapTargetOffset = result.viewPos - Double(newContainerPosition)
        let correctedTargetOffset = result.isOverscrollBoundary ? snapTargetOffset : correctedGestureTargetOffset(
            result: result,
            columns: columns,
            geometry: geometry
        )
        let pixel = 1.0 / Double(max(geometry.areas.scale, 1.0))
        let targetOffset = abs(correctedTargetOffset - snapTargetOffset) < pixel
            ? snapTargetOffset
            : correctedTargetOffset

        guard motion.animationsEnabled else {
            jumpOffset(to: CGFloat(targetOffset))
            activatePrevColumnOnRemoval = nil
            return
        }

        rebaseOffset(by: offsetDelta)
        springOffset(to: CGFloat(targetOffset), config: motion.scaled(.niriHorizontalViewMovement))

        activatePrevColumnOnRemoval = nil
    }

    private func findSnapPointsAndTarget(
        projectedViewPos: Double,
        projectedOffset: Double,
        currentOffset: Double,
        columns: [NiriContainer],
        plan: consuming NiriGestureSnapPlan
    ) -> NiriGestureSnapPlan.Point {
        guard !columns.isEmpty else { return NiriGestureSnapPlan.Point(viewPos: 0, columnIndex: 0) }
        var plan = consume plan
        if plan.geometry.isCentering {
            plan.appendCenteredPoints(in: columns)
        } else {
            let bounds = gestureSnapBounds(columns: columns, plan: &plan)
            plan.appendBoundedPoints(in: columns, bounds: bounds)
        }
        if let bounds = plan.geometry.viewport.overscrollBounds(columns: columns) {
            plan.appendPoint(Double(bounds.lowerBound), columnIndex: 0, isOverscrollBoundary: true)
            plan.appendPoint(Double(bounds.upperBound), columnIndex: columns.count - 1, isOverscrollBoundary: true)
        }
        guard let closest = plan.closestPoint(to: projectedViewPos) else {
            return NiriGestureSnapPlan.Point(viewPos: 0, columnIndex: 0)
        }
        guard !plan.geometry.isCentering, !closest.isOverscrollBoundary else { return closest }
        let columnIndex = if projectedOffset >= currentOffset {
            forwardGestureSnapColumn(closest: closest, columns: columns, geometry: plan.geometry)
        } else {
            backwardGestureSnapColumn(closest: closest, columns: columns, geometry: plan.geometry)
        }
        return NiriGestureSnapPlan.Point(viewPos: closest.viewPos, columnIndex: columnIndex)
    }

    private func gestureSnapBounds(
        columns: [NiriContainer],
        plan: inout NiriGestureSnapPlan
    ) -> (leading: Double, trailing: Double) {
        let leadingSnap = plan.geometry.snapPair(
            containerPosition: 0,
            column: columns[0],
            previousContainerSpan: nil,
            nextContainerSpan: columns.dropFirst().first.map { Double($0[keyPath: plan.geometry.sizeKeyPath]) }
        ).leading
        let lastColIdx = columns.count - 1
        let lastContainerPosition = Double(containerPosition(
            at: lastColIdx,
            containers: columns,
            gap: plan.geometry.gap,
            sizeKeyPath: plan.geometry.sizeKeyPath
        ))
        let trailingSnap = plan.geometry.snapPair(
            containerPosition: lastContainerPosition,
            column: columns[lastColIdx],
            previousContainerSpan: lastColIdx > 0
                ? Double(columns[lastColIdx - 1][keyPath: plan.geometry.sizeKeyPath])
                : nil,
            nextContainerSpan: nil
        ).trailing - plan.geometry.viewSpan

        plan.appendPoint(leadingSnap, columnIndex: 0)
        plan.appendPoint(trailingSnap, columnIndex: lastColIdx)
        return (leadingSnap, trailingSnap)
    }

    private func forwardGestureSnapColumn(
        closest: NiriGestureSnapPlan.Point,
        columns: [NiriContainer],
        geometry: NiriGestureSnapPlan.Geometry
    ) -> Int {
        var newColIdx = closest.columnIndex
        for idx in (newColIdx + 1) ..< columns.count {
            let containerPosition = Double(containerPosition(
                at: idx,
                containers: columns,
                gap: geometry.gap,
                sizeKeyPath: geometry.sizeKeyPath
            ))
            let containerSpan = Double(columns[idx][keyPath: geometry.sizeKeyPath])
            let mode = columns[idx].effectiveSizingMode
            let area = geometry.areas.area(for: mode)

            if mode.isFullscreen {
                if closest.viewPos + geometry.viewSpan < containerPosition + containerSpan {
                    break
                }
            } else {
                let areaSpan = Double(geometry.areas.span(of: area))
                let leadingStrut = Double(geometry.areas.origin(of: area))
                let padding = mode.isMaximized
                    ? 0
                    : ((areaSpan - containerSpan) / 2.0).clamped(to: 0 ... geometry.gaps)
                if closest.viewPos + leadingStrut + areaSpan
                    < containerPosition + containerSpan + padding
                {
                    break
                }
            }

            newColIdx = idx
        }
        return newColIdx
    }

    private func backwardGestureSnapColumn(
        closest: NiriGestureSnapPlan.Point,
        columns: [NiriContainer],
        geometry: NiriGestureSnapPlan.Geometry
    ) -> Int {
        var newColIdx = closest.columnIndex
        for idx in stride(from: newColIdx - 1, through: 0, by: -1) {
            let containerPosition = Double(containerPosition(
                at: idx,
                containers: columns,
                gap: geometry.gap,
                sizeKeyPath: geometry.sizeKeyPath
            ))
            let containerSpan = Double(columns[idx][keyPath: geometry.sizeKeyPath])
            let mode = columns[idx].effectiveSizingMode
            let area = geometry.areas.area(for: mode)

            if mode.isFullscreen {
                if containerPosition < closest.viewPos {
                    break
                }
            } else {
                let areaSpan = Double(geometry.areas.span(of: area))
                let leadingStrut = Double(geometry.areas.origin(of: area))
                let padding = mode.isMaximized
                    ? 0
                    : ((areaSpan - containerSpan) / 2.0).clamped(to: 0 ... geometry.gaps)
                if containerPosition - padding < closest.viewPos + leadingStrut {
                    break
                }
            }

            newColIdx = idx
        }
        return newColIdx
    }

    private func correctedGestureTargetOffset(
        result: NiriGestureSnapPlan.Point,
        columns: [NiriContainer],
        geometry: NiriGestureSnapPlan.Geometry
    ) -> Double {
        guard columns.indices.contains(result.columnIndex) else { return 0 }
        let containerPosition = Double(containerPosition(
            at: result.columnIndex,
            containers: columns,
            gap: geometry.gap,
            sizeKeyPath: geometry.sizeKeyPath
        ))
        let containerSpan = Double(columns[result.columnIndex][keyPath: geometry.sizeKeyPath])
        let mode = columns[result.columnIndex].effectiveSizingMode

        let currentViewStart = CGFloat(result.viewPos)
        let target = ViewportColumnTarget(
            index: result.columnIndex,
            position: CGFloat(containerPosition),
            span: CGFloat(containerSpan),
            mode: mode
        )
        let offset = if geometry.isCentering {
            geometry.areas.centeredOffset(
                currentViewStart: currentViewStart,
                target: target,
                gap: geometry.gap
            )
        } else {
            geometry.areas.fitOffset(
                currentViewStart: currentViewStart,
                target: target,
                gap: geometry.gap
            )
        }
        return Double(offset)
    }

    private mutating func endGestureWithMomentum(
        projectedOffset: Double,
        columns: [NiriContainer],
        geometry: NiriViewportGeometry,
        totalContentSpan: Double,
        motion: MotionSnapshot
    ) {
        let sizeKeyPath = geometry.orientation.renderedSpanKeyPath
        let oldActivePosition = containerPosition(
            at: activeColumnIndex,
            containers: columns,
            gap: geometry.gap,
            sizeKeyPath: sizeKeyPath
        )

        guard let preserved = NiriGestureMomentumPlan(
            columns: columns,
            gap: geometry.gap,
            viewportSpan: Double(geometry.viewportSpan),
            totalContentSpan: totalContentSpan,
            sizeKeyPath: sizeKeyPath,
            viewStartBounds: geometry.overscrollBounds(columns: columns).map {
                Double($0.lowerBound) ... Double($0.upperBound)
            }
        )?.landing(
            columns: columns,
            activeIndex: activeColumnIndex,
            currentOffset: projectedOffset
        ) else {
            jumpOffset(to: CGFloat(projectedOffset))
            activatePrevColumnOnRemoval = nil
            return
        }

        let newActivePosition = containerPosition(
            at: preserved.normalizedActiveColumn,
            containers: columns,
            gap: geometry.gap,
            sizeKeyPath: sizeKeyPath
        )
        let offsetDelta = oldActivePosition - newActivePosition

        if activeColumnIndex != preserved.normalizedActiveColumn {
            viewOffsetToRestore = nil
        }
        activeColumnIndex = preserved.normalizedActiveColumn

        let maxViewStart = max(0, totalContentSpan - Double(geometry.viewportSpan))
        let bounds = geometry.overscrollBounds(columns: columns).map {
            Double($0.lowerBound) ... Double($0.upperBound)
        } ?? (0 ... maxViewStart)
        let overscrolled = !bounds.contains(Double(oldActivePosition) + projectedOffset)

        guard motion.animationsEnabled else {
            jumpOffset(to: CGFloat(preserved.finalOffset))
            activatePrevColumnOnRemoval = nil
            return
        }

        rebaseOffset(by: offsetDelta)
        if overscrolled {
            springOffset(to: CGFloat(preserved.finalOffset), config: motion.scaled(.niriHorizontalViewMovement))
        } else {
            decelerateOffset(to: CGFloat(preserved.finalOffset))
        }
        activatePrevColumnOnRemoval = nil
    }

    private mutating func endGestureWithoutSnap(currentOffset: Double) {
        jumpOffset(to: CGFloat(currentOffset))
        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
    }
}
