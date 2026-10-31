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

    func edgePeekCap(at index: Int, of count: Int, viewFrame: CGRect?, workingFrame: CGRect, gap: CGFloat) -> CGFloat? {
        guard count > 1, let viewFrame, let peeks = edgePeekWidths(viewFrame: viewFrame) else { return nil }
        let room = edgePeekRoom(at: index, of: count, viewFrame: viewFrame, workingFrame: workingFrame, peeks: peeks)
        return max(1, room.maxX - room.minX - 2 * gap)
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
        for (index, column) in columns.enumerated() {
            let columnCap = orientation != .horizontal || column.isLiveHomeSpot || column.isLiveDropSpace
                ? nil
                : edgePeekCap(at: index, of: columns.count, viewFrame: viewFrame, workingFrame: workingFrame, gap: gap)
            guard column.edgePeekCap != columnCap else { continue }
            column.edgePeekCap = columnCap
            column.invalidateCachedPrimarySpan(orientation: .horizontal)
        }
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
        applyEdgePeekCaps(to: hidden, viewFrame: nil, workingFrame: workingFrame, gap: gap, orientation: orientation)
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
