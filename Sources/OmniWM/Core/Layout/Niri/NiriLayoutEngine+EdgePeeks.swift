// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct EdgePeekWidths: Equatable {
    var leading: CGFloat
    var trailing: CGFloat
}

extension NiriLayoutEngine {
    func edgePeekWidths(viewFrame: CGRect?) -> EdgePeekWidths? {
        guard let edgePeekShare, let viewFrame else { return nil }
        let width = (viewFrame.width * edgePeekShare).rounded()
        let others = monitors.values.map(\.frame).filter { $0 != viewFrame }
        func shared(_ edge: CGFloat, _ otherEdge: (CGRect) -> CGFloat) -> Bool {
            others.contains { other in
                abs(otherEdge(other) - edge) < 1 && other.maxY > viewFrame.minY && other.minY < viewFrame.maxY
            }
        }
        return EdgePeekWidths(
            leading: shared(viewFrame.minX, \.maxX) ? 0 : width,
            trailing: shared(viewFrame.maxX, \.minX) ? 0 : width
        )
    }

    func edgePeekWidths(in workspaceId: WorkspaceDescriptor.ID) -> EdgePeekWidths? {
        guard let monitor = monitorForWorkspace(workspaceId), monitor.orientation == .horizontal else { return nil }
        return edgePeekWidths(viewFrame: monitor.frame)
    }

    private func edgePeekRoom(
        at index: Int,
        of count: Int,
        viewFrame: CGRect,
        workingFrame: CGRect,
        peeks: EdgePeekWidths
    ) -> (minX: CGFloat, maxX: CGFloat) {
        let minX = index > 0 ? max(workingFrame.minX, viewFrame.minX + peeks.leading) : workingFrame.minX
        let maxX = index < count - 1 ? min(workingFrame.maxX, viewFrame.maxX - peeks.trailing) : workingFrame.maxX
        return (minX, maxX)
    }

    func applyEdgePeekCaps(
        to columns: [NiriContainer],
        viewFrame: CGRect?,
        workingFrame: CGRect,
        gap: CGFloat,
        orientation: Monitor.Orientation
    ) {
        let peeks = columns.count > 1 && orientation == .horizontal
            ? viewFrame.flatMap { edgePeekWidths(viewFrame: $0) }
            : nil
        for (index, column) in columns.enumerated() {
            var columnCap: CGFloat?
            if let viewFrame, let peeks, !column.isLiveHomeSpot, !column.isLiveDropSpace {
                let room = edgePeekRoom(
                    at: index,
                    of: columns.count,
                    viewFrame: viewFrame,
                    workingFrame: workingFrame,
                    peeks: peeks
                )
                columnCap = max(1, room.maxX - room.minX - 2 * gap)
            }
            guard column.edgePeekCap != columnCap else { continue }
            column.edgePeekCap = columnCap
            column.invalidateCachedPrimarySpan(orientation: .horizontal)
        }
        applyStripEndPeekCaps(to: columns, viewFrame: viewFrame, workingFrame: workingFrame, gap: gap, peeks: peeks)
    }

    private func applyStripEndPeekCaps(
        to columns: [NiriContainer],
        viewFrame: CGRect?,
        workingFrame: CGRect,
        gap: CGFloat,
        peeks: EdgePeekWidths?
    ) {
        let previous = columns.map(\.stripEndPeekCap)
        columns.forEach { $0.stripEndPeekCap = nil }
        var caps = [CGFloat?](repeating: nil, count: columns.count)
        if let viewFrame, let peeks, columns.count > 2 {
            let spans = columns.map { column in
                column.resolvedWidthPixels(
                    column.isFullWidth ? .proportion(1) : column.width,
                    availableSpan: workingFrame.width,
                    gaps: gap,
                    contentInset: tabContentInset(for: column)
                )
            }
            let first = Self.peekShortfall(
                spans: spans,
                inset: workingFrame.minX + gap - viewFrame.minX,
                viewSpan: viewFrame.width,
                peek: peeks.trailing,
                gap: gap
            )
            let last = Self.peekShortfall(
                spans: spans.reversed(),
                inset: viewFrame.maxX - workingFrame.maxX + gap,
                viewSpan: viewFrame.width,
                peek: peeks.leading,
                gap: gap
            )
            if first > 0 { caps[0] = spans[0] - first }
            if last > 0 { caps[columns.count - 1] = spans[columns.count - 1] - last }
        }
        for (index, column) in columns.enumerated() {
            guard !column.isLiveHomeSpot, !column.isLiveDropSpace else { continue }
            column.stripEndPeekCap = caps[index]
            if caps[index] != previous[index] {
                column.invalidateCachedPrimarySpan(orientation: .horizontal)
            }
        }
    }

    private static func peekShortfall(
        spans: [CGFloat],
        inset: CGFloat,
        viewSpan: CGFloat,
        peek: CGFloat,
        gap: CGFloat
    ) -> CGFloat {
        guard peek > 0, let endSpan = spans.first else { return 0 }
        var position = inset + endSpan + gap
        for span in spans.dropFirst() {
            if position + span > viewSpan {
                return max(0, position - (viewSpan - peek))
            }
            position += span + gap
        }
        return 0
    }

    func applyEdgePeekCaps(in workspaceId: WorkspaceDescriptor.ID, workingFrame: CGRect, gap: CGFloat) {
        guard !isLiveColumnMoveActive(in: workspaceId),
              edgePeekShare != nil || columns(in: workspaceId).contains(where: { $0.edgePeekCap != nil })
        else { return }
        let monitor = monitorForWorkspace(workspaceId)
        let orientation = monitor?.orientation ?? .horizontal
        let projected = projectedColumns(in: workspaceId)
        let projectedIds = Set(projected.map { ObjectIdentifier($0.column) })
        let hidden = columns(in: workspaceId).filter { !projectedIds.contains(ObjectIdentifier($0)) }
        applyEdgePeekCaps(
            to: projected.map(\.column),
            viewFrame: monitor?.frame,
            workingFrame: workingFrame,
            gap: gap,
            orientation: orientation
        )
        for column in hidden where column.edgePeekCap != nil {
            column.edgePeekCap = nil
            column.invalidateCachedPrimarySpan(orientation: .horizontal)
        }
    }

    func edgePeekBounds(of column: NiriContainer, context: NiriInteractionContext) -> ClosedRange<CGFloat> {
        let lowest = context.workingFrame.minX + context.gaps
        let highest = max(lowest, context.workingFrame.maxX - context.gaps)
        guard context.orientation == .horizontal,
              let viewFrame = monitorForWorkspace(context.workspaceId)?.frame,
              let peeks = edgePeekWidths(viewFrame: viewFrame)
        else { return lowest ... highest }
        let projected = projectedColumns(in: context.workspaceId)
        guard projected.count > 1, let index = projected.firstIndex(where: { $0.column === column }) else {
            return lowest ... highest
        }
        let room = edgePeekRoom(
            at: index,
            of: projected.count,
            viewFrame: viewFrame,
            workingFrame: context.workingFrame,
            peeks: peeks
        )
        let minX = max(lowest, room.minX + context.gaps)
        let maxX = min(highest, room.maxX - context.gaps)
        return minX ... max(minX, maxX)
    }
}

extension NiriLayoutEngine {
    func settledCoverageOffset(for input: NiriSettledCoverageEvaluator.Input) -> CGFloat {
        let offset = NiriSettledCoverageEvaluator.bestOffset(for: input)
        guard input.orientation == .horizontal,
              input.containerSpans.indices.contains(input.activeIndex),
              let peeks = edgePeekWidths(viewFrame: input.sourceMonitor.frame)
        else { return offset }
        let areas = ViewportFittingAreas(geometry: NiriViewportGeometry(
            gap: input.gap,
            viewportSpan: input.workingFrame.width,
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
