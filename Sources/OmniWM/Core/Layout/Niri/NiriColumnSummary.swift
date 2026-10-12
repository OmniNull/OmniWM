// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

enum NiriColumnViewportRelation: Equatable {
    case before
    case intersecting
    case after
}

struct NiriColumnSummary: Equatable {
    let columnIndexByToken: [WindowToken: Int]
    let viewport: [NiriColumnViewportRelation]?
}

extension NiriLayoutEngine {
    func columnSummary(
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        geometry: NiriSizingGeometry?
    ) -> NiriColumnSummary {
        let columns = projectedColumns(in: workspaceId)
        var columnIndexByToken: [WindowToken: Int] = [:]
        for (offset, column) in columns.enumerated() {
            for window in column.windows {
                columnIndexByToken[window.token] = offset + 1
            }
        }
        return NiriColumnSummary(
            columnIndexByToken: columnIndexByToken,
            viewport: geometry.map { viewportRelations(of: columns, in: workspaceId, state: state, geometry: $0) }
        )
    }

    private func viewportRelations(
        of columns: [NiriProjectedColumn],
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        geometry: NiriSizingGeometry
    ) -> [NiriColumnViewportRelation] {
        guard !columns.isEmpty else { return [] }
        let frame = geometry.workingFrame
        let isHorizontal = geometry.orientation == .horizontal
        let spans = columns.map { settledPrimarySpan(of: $0, geometry: geometry) }
        var positions: [CGFloat] = []
        positions.reserveCapacity(spans.count)
        var position: CGFloat = 0
        for span in spans {
            positions.append(position)
            position += span + geometry.gaps
        }

        let activeIndex = projectedActiveColumnIndex(state: state, columns: columns, in: workspaceId)
        let viewportSpan = isHorizontal ? frame.width : frame.height
        let contentInset = settledContentInset(
            viewportSpan: viewportSpan,
            activeSpan: spans[activeIndex],
            gap: geometry.gaps
        )
        let viewStart = positions[activeIndex] + state.viewOffset
        let tolerance = 0.5 / max(displayScale(in: workspaceId), 1)
        let placementMonitor = monitorForWorkspace(workspaceId).map(HiddenPlacementMonitorContext.init)
        let placementMonitors = monitors.values.map(HiddenPlacementMonitorContext.init)

        return columns.indices.map { index in
            guard index != activeIndex else { return .intersecting }
            let start = positions[index] - viewStart
            let parksOutsideContent = columns[index].windows.allSatisfy {
                $0.sizingMode == .normal && $0.id != state.selectedNodeId
            }
            let inset = (parksOutsideContent ? contentInset : 0) + tolerance
            if start + spans[index] <= inset { return .before }
            if start >= viewportSpan - inset { return .after }
            let rect = isHorizontal
                ? CGRect(x: frame.minX + start, y: frame.minY, width: spans[index], height: frame.height)
                : CGRect(x: frame.minX, y: frame.minY + start, width: frame.width, height: spans[index])
            switch NiriMonitorPlaneGeometry.overflowEdgeIntersectingNeighboringMonitor(
                rect,
                viewportFrame: frame,
                orientation: geometry.orientation,
                hiddenPlacementMonitor: placementMonitor,
                hiddenPlacementMonitors: placementMonitors
            ) {
            case .minimum: return .before
            case .maximum: return .after
            case nil: return .intersecting
            }
        }
    }

    private func settledPrimarySpan(of column: NiriProjectedColumn, geometry: NiriSizingGeometry) -> CGFloat {
        let cachedSpan = projectedPrimarySpan(
            for: column,
            workingFrame: geometry.workingFrame,
            gap: geometry.gaps,
            orientation: geometry.orientation
        )
        let span = cachedSpan > 0 ? cachedSpan : rawProjectedPrimarySpan(
            for: column,
            workingFrame: geometry.workingFrame,
            gap: geometry.gaps,
            orientation: geometry.orientation
        )
        return geometry.orientation == .horizontal ? column.column.targetWidth ?? span : span
    }
}
