// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

enum NiriColumnViewportRelation: Equatable {
    case before
    case intersecting
    case after
}

struct NiriProjectionMembership {
    let excludedTokens: Set<WindowToken>
    let heldTabs: [NiriWindow]

    var admitsEveryWindow: Bool {
        excludedTokens.isEmpty && heldTabs.isEmpty
    }

    func admits(_ token: WindowToken) -> Bool {
        guard !excludedTokens.contains(token) else { return false }
        return heldTabs.withUnsafeBufferPointer { tabs in
            for index in tabs.indices where tabs[index].token == token {
                return false
            }
            return true
        }
    }
}

struct NiriViewportScratch {
    fileprivate(set) var relations: [NiriColumnViewportRelation] = []
    fileprivate var spans: [CGFloat] = []
    fileprivate var positions: [CGFloat] = []
    fileprivate var placementMonitors: [HiddenPlacementMonitorContext] = []
    fileprivate var placementMonitorsCollected = false

    mutating func recollectPlacementMonitors() {
        placementMonitorsCollected = false
    }
}

private struct NiriViewportWindow {
    let frame: CGRect
    let orientation: Monitor.Orientation
    let viewStart: CGFloat
    let contentInset: CGFloat
    let tolerance: CGFloat
    let placementMonitor: HiddenPlacementMonitorContext?

    func relation(
        start position: CGFloat, span: CGFloat, parks: Bool, monitors: [HiddenPlacementMonitorContext]
    ) -> NiriColumnViewportRelation {
        let isHorizontal = orientation == .horizontal
        let start = position - viewStart
        let inset = (parks ? contentInset : 0) + tolerance
        if start + span <= inset { return .before }
        if start >= (isHorizontal ? frame.width : frame.height) - inset { return .after }
        let rect = isHorizontal
            ? CGRect(x: frame.minX + start, y: frame.minY, width: span, height: frame.height)
            : CGRect(x: frame.minX, y: frame.minY + start, width: frame.width, height: span)
        switch NiriMonitorPlaneGeometry.overflowEdgeIntersectingNeighboringMonitor(
            rect,
            viewportFrame: frame,
            orientation: orientation,
            hiddenPlacementMonitor: placementMonitor,
            hiddenPlacementMonitors: monitors
        ) {
        case .minimum: return .before
        case .maximum: return .after
        case nil: return .intersecting
        }
    }
}

struct NiriColumnSummary: Equatable {
    let columnIndexByToken: [WindowToken: Int]
    let viewport: [NiriColumnViewportRelation]?
    let displayModes: [ColumnDisplay]?

    init(
        columnIndexByToken: [WindowToken: Int],
        viewport: [NiriColumnViewportRelation]?,
        displayModes: [ColumnDisplay]? = nil
    ) {
        self.columnIndexByToken = columnIndexByToken
        self.viewport = viewport
        self.displayModes = displayModes
    }
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
            viewport: geometry.map { viewportRelations(of: columns, in: workspaceId, state: state, geometry: $0) },
            displayModes: columns.map { $0.column.displayMode }
        )
    }

    func projectionMembership(in workspaceId: WorkspaceDescriptor.ID) -> NiriProjectionMembership {
        NiriProjectionMembership(
            excludedTokens: projectionExclusions(in: workspaceId),
            heldTabs: liveColumnMove?.workspaceId == workspaceId ? liveColumnMove?.heldTabs ?? [] : []
        )
    }

    func projectedSlot(
        of column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        membership: NiriProjectionMembership
    ) -> (index: Int, count: Int)? {
        guard let root = root(for: workspaceId) else { return nil }
        let liveHomeColumnId = liveHomeColumnId
        var index: Int?
        var count = 0
        for case let candidate as NiriContainer in root.children where membership.admitsEveryWindow
            || holdsLiveSpace(candidate, home: liveHomeColumnId)
            || candidate.children.contains(where: { ($0 as? NiriWindow).map { membership.admits($0.token) } == true })
        {
            if candidate === column { index = count }
            count += 1
        }
        return index.map { (index: $0, count: count) }
    }

    func viewportRelations(
        of columns: [NiriProjectedColumn],
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        geometry: NiriSizingGeometry
    ) -> [NiriColumnViewportRelation] {
        var scratch = NiriViewportScratch()
        viewportRelations(of: columns, in: workspaceId, state: state, geometry: geometry, into: &scratch)
        return scratch.relations
    }

    func viewportRelations(
        of columns: [NiriProjectedColumn],
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        geometry: NiriSizingGeometry,
        into scratch: inout NiriViewportScratch
    ) {
        scratch.relations.removeAll(keepingCapacity: true)
        guard !columns.isEmpty else { return }
        let projected = columns.span
        measure(projected, geometry: geometry, into: &scratch)
        if !scratch.placementMonitorsCollected {
            scratch.placementMonitors.removeAll(keepingCapacity: true)
            scratch.placementMonitors.reserveCapacity(monitors.count)
            for monitor in monitors.values {
                scratch.placementMonitors.append(HiddenPlacementMonitorContext(monitor))
            }
            scratch.placementMonitorsCollected = true
        }
        let activeIndex = projectedActiveColumnIndex(state: state, columns: columns, in: workspaceId)
        let frame = geometry.workingFrame
        let viewport = NiriViewportWindow(
            frame: frame,
            orientation: geometry.orientation,
            viewStart: scratch.positions[activeIndex] + state.viewOffset,
            contentInset: settledContentInset(
                viewportSpan: geometry.orientation == .horizontal ? frame.width : frame.height,
                activeSpan: scratch.spans[activeIndex],
                gap: geometry.gaps
            ),
            tolerance: 0.5 / max(displayScale(in: workspaceId), 1),
            placementMonitor: monitorForWorkspace(workspaceId).map(HiddenPlacementMonitorContext.init)
        )
        scratch.relations.reserveCapacity(projected.count)
        for index in projected.indices {
            let relation = index == activeIndex ? .intersecting : viewport.relation(
                start: scratch.positions[index], span: scratch.spans[index],
                parks: Self.parksOutsideContent(projected[index].windows.span, selected: state.selectedNodeId),
                monitors: scratch.placementMonitors
            )
            scratch.relations.append(relation)
        }
    }

    private func measure(
        _ projected: Span<NiriProjectedColumn>, geometry: NiriSizingGeometry, into scratch: inout NiriViewportScratch
    ) {
        scratch.spans.removeAll(keepingCapacity: true)
        scratch.positions.removeAll(keepingCapacity: true)
        scratch.spans.reserveCapacity(projected.count)
        scratch.positions.reserveCapacity(projected.count)
        var position: CGFloat = 0
        for index in projected.indices {
            let span = settledPrimarySpan(of: projected[index], geometry: geometry)
            scratch.spans.append(span)
            scratch.positions.append(position)
            position += span + geometry.gaps
        }
    }

    static func parksOutsideContent(_ windows: Span<NiriWindow>, selected: NodeId?) -> Bool {
        for offset in windows.indices {
            if windows[offset].sizingMode != .normal { return false }
            if windows[offset].id == selected { return false }
        }
        return true
    }

    private func settledPrimarySpan(of column: borrowing NiriProjectedColumn, geometry: NiriSizingGeometry) -> CGFloat {
        settledPrimarySpan(of: column.column, windows: column.windows.span, geometry: geometry)
    }

    func settledPrimarySpan(
        of column: borrowing NiriContainer, windows: borrowing Span<NiriWindow>, geometry: NiriSizingGeometry,
        fullMembership: Bool? = nil
    ) -> CGFloat {
        let cachedSpan = projectedPrimarySpan(
            of: column, windows: windows, geometry: geometry, fullMembership: fullMembership
        )
        let span = cachedSpan > 0 ? cachedSpan : rawProjectedPrimarySpan(
            of: column,
            windows: windows,
            geometry: geometry
        )
        return switch geometry.orientation {
        case .horizontal: column.targetWidth ?? span
        case .vertical: column.targetHeight ?? span
        }
    }
}
