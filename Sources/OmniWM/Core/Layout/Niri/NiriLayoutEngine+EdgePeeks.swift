// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct EdgePeekSpans: Equatable {
    var leading: CGFloat
    var trailing: CGFloat
}

extension NiriLayoutEngine {
    func refreshEdgePeeksPossible() {
        edgePeeksPossible = edgePeekShare != nil
            || monitors.values.contains { $0.resolvedSettings?.edgePeekShare != nil }
    }

    func edgePeekShare(onDisplayWith viewFrame: CGRect?) -> CGFloat? {
        guard let viewFrame else { return nil }
        return edgePeekShare(on: monitors.values.first(where: { $0.frame == viewFrame }))
    }

    private func edgePeekShare(on monitor: NiriMonitor?) -> CGFloat? {
        guard let resolved = monitor?.resolvedSettings else { return edgePeekShare }
        return resolved.edgePeekShare
    }

    func edgePeekSpans(viewFrame: CGRect?, orientation: Monitor.Orientation) -> EdgePeekSpans? {
        guard let viewFrame, let share = edgePeekShare(onDisplayWith: viewFrame) else { return nil }
        let horizontal = orientation == .horizontal
        let span = ((horizontal ? viewFrame.width : viewFrame.height) * share).rounded()
        var leading = span
        var trailing = span
        for other in monitors.values.lazy.map(\.frame) {
            guard other != viewFrame else { continue }
            let overlaps = horizontal
                ? other.maxY > viewFrame.minY && other.minY < viewFrame.maxY
                : other.maxX > viewFrame.minX && other.minX < viewFrame.maxX
            guard overlaps else { continue }
            if abs(horizontal ? other.maxX - viewFrame.minX : other.maxY - viewFrame.minY) < 1 { leading = 0 }
            if abs(horizontal ? other.minX - viewFrame.maxX : other.minY - viewFrame.maxY) < 1 { trailing = 0 }
        }
        return EdgePeekSpans(leading: leading, trailing: trailing)
    }

    func edgePeekSpans(in workspaceId: WorkspaceDescriptor.ID) -> EdgePeekSpans? {
        guard let monitor = monitorForWorkspace(workspaceId) else { return nil }
        return edgePeekSpans(viewFrame: monitor.frame, orientation: monitor.orientation)
    }

    private func edgePeekRoom(
        at index: Int,
        of count: Int,
        frames: (view: CGRect, working: CGRect),
        peeks: EdgePeekSpans,
        orientation: Monitor.Orientation
    ) -> (start: CGFloat, end: CGFloat) {
        let (viewFrame, workingFrame) = frames
        let horizontal = orientation == .horizontal
        let workingStart = horizontal ? workingFrame.minX : workingFrame.minY
        let workingEnd = horizontal ? workingFrame.maxX : workingFrame.maxY
        let viewStart = horizontal ? viewFrame.minX : viewFrame.minY
        let viewEnd = horizontal ? viewFrame.maxX : viewFrame.maxY
        let start = index > 0 ? max(workingStart, viewStart + peeks.leading) : workingStart
        let end = index < count - 1 ? min(workingEnd, viewEnd - peeks.trailing) : workingEnd
        return (start, end)
    }

    func applyEdgePeekCaps(
        to columns: [NiriContainer],
        viewFrame: CGRect?,
        workingFrame: CGRect,
        gap: CGFloat,
        orientation: Monitor.Orientation
    ) {
        let placed = columns.contains { $0.isLiveHomeSpot || $0.isLiveDropSpace }
            ? columns.filter { !$0.isLiveHomeSpot && !$0.isLiveDropSpace }
            : columns
        let peeks = placed.count > 1
            ? viewFrame.flatMap { edgePeekSpans(viewFrame: $0, orientation: orientation) }
            : nil
        for (index, column) in placed.enumerated() {
            let cap = viewFrame.flatMap { viewFrame in
                peeks.map { peeks in
                    let room = edgePeekRoom(
                        at: index,
                        of: placed.count,
                        frames: (viewFrame, workingFrame),
                        peeks: peeks,
                        orientation: orientation
                    )
                    return max(1, room.end - room.start - 2 * gap)
                }
            }
            guard column.edgePeekCap != cap else { continue }
            if cap != nil { hasSetEdgePeekCaps = true }
            column.edgePeekCap = cap
            column.invalidateCachedPrimarySpan(orientation: orientation)
        }
        applyStripEndPeekCaps(
            to: placed, frames: (viewFrame, workingFrame), gap: gap, peeks: peeks,
            orientation: orientation
        )
    }

    private func applyStripEndPeekCaps(
        to columns: [NiriContainer],
        frames: (view: CGRect?, working: CGRect),
        gap: CGFloat,
        peeks: EdgePeekSpans?,
        orientation: Monitor.Orientation
    ) {
        let (viewFrame, workingFrame) = frames
        let previousFirst = columns.first?.stripEndPeekRoom
        let previousLast = columns.last?.stripEndPeekRoom
        var staleMiddle: [Int] = []
        for index in columns.indices where columns[index].stripEndPeekRoom != nil {
            columns[index].stripEndPeekRoom = nil
            if index != 0, index != columns.count - 1 { staleMiddle.append(index) }
        }
        var firstRoom: StripEndPeekRoom?
        var lastRoom: StripEndPeekRoom?
        if let viewFrame, let peeks, columns.count > 2 {
            let horizontal = orientation == .horizontal
            let spans = columns.map { column in
                let isFull = horizontal ? column.isFullWidth : column.isFullHeight
                let spec = horizontal ? column.width : column.height
                return column.resolvedPrimarySpan(
                    isFull ? .proportion(1) : spec,
                    orientation: orientation,
                    availableSpace: horizontal ? workingFrame.width : workingFrame.height,
                    gaps: gap,
                    contentInset: horizontal ? tabContentInset(for: column) : 0
                )
            }
            firstRoom = StripEndPeekRoom(
                farSpans: Array(spans.dropFirst()),
                inset: (horizontal ? workingFrame.minX - viewFrame.minX : workingFrame.minY - viewFrame.minY) + gap,
                viewSpan: horizontal ? viewFrame.width : viewFrame.height,
                peek: peeks.trailing,
                gap: gap
            )
            lastRoom = StripEndPeekRoom(
                farSpans: Array(spans.dropLast().reversed()),
                inset: (horizontal ? viewFrame.maxX - workingFrame.maxX : viewFrame.maxY - workingFrame.maxY) + gap,
                viewSpan: horizontal ? viewFrame.width : viewFrame.height,
                peek: peeks.leading,
                gap: gap
            )
        }
        for index in staleMiddle {
            columns[index].invalidateCachedPrimarySpan(orientation: orientation)
        }
        if let first = columns.first {
            first.stripEndPeekRoom = firstRoom
            if firstRoom != previousFirst { first.invalidateCachedPrimarySpan(orientation: orientation) }
        }
        if columns.count > 1, let last = columns.last {
            last.stripEndPeekRoom = lastRoom
            if lastRoom != previousLast { last.invalidateCachedPrimarySpan(orientation: orientation) }
        }
    }

    func applyEdgePeekCaps(in workspaceId: WorkspaceDescriptor.ID, workingFrame: CGRect, gap: CGFloat) {
        guard edgePeeksPossible || hasSetEdgePeekCaps else { return }
        let monitor = monitorForWorkspace(workspaceId)
        guard !isLiveColumnMoveActive(in: workspaceId),
              monitor != nil && edgePeekShare(on: monitor) != nil
              || hasSetEdgePeekCaps && columns(in: workspaceId).contains(where: { $0.edgePeekCap != nil })
        else { return }
        let orientation = monitor?.orientation ?? .horizontal
        let projected = projectedColumns(in: workspaceId)
        applyEdgePeekCaps(
            to: projected.map(\.column),
            viewFrame: monitor?.frame,
            workingFrame: workingFrame,
            gap: gap,
            orientation: orientation
        )
        let all = columns(in: workspaceId)
        guard projected.count != all.count else { return }
        for column in all
            where column.edgePeekCap != nil && !projected.contains(where: { $0.column === column })
        {
            column.edgePeekCap = nil
            column.invalidateCachedPrimarySpan(orientation: orientation)
        }
    }

    func edgePeekBounds(of column: NiriContainer, context: NiriInteractionContext) -> ClosedRange<CGFloat> {
        let horizontal = context.orientation == .horizontal
        let lowest = (horizontal ? context.workingFrame.minX : context.workingFrame.minY) + context.gaps
        let highest = max(lowest, (horizontal ? context.workingFrame.maxX : context.workingFrame.maxY) - context.gaps)
        guard let viewFrame = monitorForWorkspace(context.workspaceId)?.frame,
              let peeks = edgePeekSpans(viewFrame: viewFrame, orientation: context.orientation)
        else { return lowest ... highest }
        let projected = projectedColumns(in: context.workspaceId)
        guard projected.count > 1, let index = projected.firstIndex(where: { $0.column === column }) else {
            return lowest ... highest
        }
        let room = edgePeekRoom(
            at: index,
            of: projected.count,
            frames: (viewFrame, context.workingFrame),
            peeks: peeks,
            orientation: context.orientation
        )
        let start = max(lowest, room.start + context.gaps)
        let end = min(highest, room.end - context.gaps)
        return start ... max(start, end)
    }
}

extension NiriLayoutEngine {
    func settledCoverageOffset(for input: NiriSettledCoverageEvaluator.Input) -> CGFloat {
        let offset = NiriSettledCoverageEvaluator.bestOffset(for: input)
        guard input.containerSpans.indices.contains(input.activeIndex),
              let peeks = edgePeekSpans(viewFrame: input.sourceMonitor.frame, orientation: input.orientation)
        else { return offset }
        let areas = ViewportFittingAreas(geometry: NiriViewportGeometry(
            gap: input.gap,
            viewportSpan: input.orientation == .horizontal ? input.workingFrame.width : input.workingFrame.height,
            orientation: input.orientation,
            workingArea: input.workingFrame,
            viewFrame: input.sourceMonitor.frame,
            scale: input.scale,
            edgePeeks: peeks
        ))
        let activePosition = input.containerSpans.prefix(input.activeIndex).reduce(0) { $0 + $1 + input.gap }
        let viewStart = areas.viewStartRestoringEdgePeeks(
            activePosition + offset,
            spans: input.containerSpans,
            gap: input.gap
        )
        return viewStart - activePosition
    }
}

struct StripEndPeekRoom: Equatable {
    var farSpans: [CGFloat]
    var inset: CGFloat
    var viewSpan: CGFloat
    var peek: CGFloat
    var gap: CGFloat

    func cappedSpan(_ span: CGFloat) -> CGFloat {
        guard peek > 0 else { return span }
        var position = inset + span + gap
        for farSpan in farSpans {
            if position + farSpan > viewSpan {
                return span - max(0, position - (viewSpan - peek))
            }
            position += farSpan + gap
        }
        return span
    }
}
