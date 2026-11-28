// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

extension NiriLayoutEngine {
    func requestAutoFit(in workspaceId: WorkspaceDescriptor.ID) {
        guard shrinkToFit else { return }
        ensureState(for: workspaceId).autoFitRequested = true
    }

    func autoFitIfRequested(
        context: NiriInteractionContext, projection: borrowing Span<NiriProjectedColumn>, state: inout ViewportState
    ) {
        assertSanctionedMutation()
        let paused = interactiveResize?.workspaceId == context.workspaceId
            || state.preservesGestureOffset || state.offsetTransition.kind == .deceleration
        var columnCount = 0
        for index in projection.indices where !projection[index].windows.isEmpty { columnCount += 1 }
        guard let request = pendingAutoFit(context: context, columnCount: columnCount, paused: paused) else { return }

        guard columnCount > 0 else { return }
        let projected = Self.admittedFitColumns(projection, count: columnCount)
        let active = projected[projectedActiveColumnIndex(state: state, columns: projected, in: context.workspaceId)]
        guard let focusIndex = projected.firstIndex(where: { $0.column === active.column }),
              let run = autoFitRun(
                  projected,
                  focusIndex: focusIndex,
                  visibleCount: request.visibleCount,
                  context: context,
                  state: state
              ),
              !run.contains(where: { isFullSpan($0.column, context: context) })
        else { return }

        let excess = autoFitExcess(run, usingFittedSpans: !request.basisChanged, context: context)
        let tolerance = 1 / displayScale(in: context.workspaceId)
        let fullRun = run.count == min(request.visibleCount, projected.count)
        if excess > tolerance || (!fullRun && abs(excess) > tolerance) {
            let workspace = ensureState(for: context.workspaceId)
            switch context.orientation {
            case .horizontal: workspace.manualWidthColumnCount = projected.count
            case .vertical: workspace.manualHeightColumnCount = projected.count
            }
            if run.count > 1 {
                shrinkVisibleColumnsToFit(around: active.column, onScreen: run, context: context, state: &state)
            } else {
                alignViewport(toFirstOf: run, context: context, state: &state)
            }
        } else if run.count > 1,
                  fullRun,
                  abs(excess) <= tolerance,
                  effectiveSettings(in: context.workspaceId).centerFocusedColumn != .always
        {
            alignViewport(toFirstOf: run, context: context, state: &state)
        }
    }

    private static func admittedFitColumns(
        _ projection: borrowing Span<NiriProjectedColumn>, count: Int
    ) -> [NiriProjectedColumn] {
        var columns: [NiriProjectedColumn] = []
        columns.reserveCapacity(count)
        for index in projection.indices where !projection[index].windows.isEmpty {
            columns.append(projection[index])
        }
        return columns
    }

    private func pendingAutoFit(
        context: NiriInteractionContext, columnCount: Int, paused: Bool
    ) -> (basisChanged: Bool, visibleCount: Int)? {
        let workspaceId = context.workspaceId
        if states[workspaceId] == nil { _ = ensureState(for: workspaceId) }
        let input = AutoFitInput(
            workspaceId: workspaceId,
            geometry: NiriShrinkToFitGeometry(
                context.workingFrame, gaps: context.gaps, orientation: context.orientation
            ),
            defaultVisibleCount: visibleContainerCount,
            columnCount: columnCount,
            paused: paused
        )
        return Self.takeAutoFitRequest(in: &states, monitors: &monitors, input: input)
    }

    private struct AutoFitInput {
        let workspaceId: WorkspaceDescriptor.ID
        let geometry: NiriShrinkToFitGeometry
        let defaultVisibleCount: Int
        let columnCount: Int
        let paused: Bool
    }

    private static func takeAutoFitRequest(
        in states: inout [WorkspaceDescriptor.ID: NiriWorkspaceState],
        monitors: inout [Monitor.ID: NiriMonitor],
        input: AutoFitInput
    ) -> (basisChanged: Bool, visibleCount: Int)? {
        guard let workspaceIndex = states.index(forKey: input.workspaceId) else { return nil }
        return takeAutoFitRequest(
            workspace: &states.values[workspaceIndex], monitors: &monitors, input: input
        )
    }

    private static func takeAutoFitRequest(
        workspace: inout NiriWorkspaceState,
        monitors: inout [Monitor.ID: NiriMonitor],
        input: AutoFitInput
    ) -> (basisChanged: Bool, visibleCount: Int)? {
        let visibleCount = if let monitorId = workspace.attachedMonitorId,
                              let monitorIndex = monitors.index(forKey: monitorId)
        {
            autoFitVisibleCount(on: &monitors.values[monitorIndex], input: input)
        } else {
            input.defaultVisibleCount
        }
        let basis = NiriAutoFitBasis(
            geometry: input.geometry,
            visibleCount: visibleCount,
            columnCount: input.columnCount
        )
        let basisChanged = workspace.autoFitBasis.map { $0 != basis } ?? false
        if workspace.autoFitBasis != basis {
            workspace.autoFitBasis = basis
            workspace.autoFitRequested = true
        }
        guard workspace.autoFitRequested, !input.paused else { return nil }
        workspace.autoFitRequested = false
        return (basisChanged, visibleCount)
    }

    private static func autoFitVisibleCount(on monitor: inout NiriMonitor, input: AutoFitInput) -> Int {
        guard monitor.containsWorkspace(input.workspaceId) else { return input.defaultVisibleCount }
        return monitor.resolvedSettings?.visibleContainerCount ?? input.defaultVisibleCount
    }

    private func autoFitRun(
        _ projected: [NiriProjectedColumn],
        focusIndex: Int,
        visibleCount: Int,
        context: NiriInteractionContext,
        state: ViewportState
    ) -> [NiriProjectedColumn]? {
        let span = context.orientation == .horizontal ? context.workingFrame.width : context.workingFrame.height
        let tolerance = 1 / displayScale(in: context.workspaceId)
        let minimums = projected.map {
            constrainedProjectedPrimarySpan(
                0, for: $0, workingFrame: context.workingFrame, gap: context.gaps, orientation: context.orientation
            )
        }
        let viewStart = onScreenProjectedColumns(
            in: context.workspaceId,
            state: state,
            geometry: context.sizingGeometry
        )
        .first.flatMap { first in projected.firstIndex { $0.column === first.column } } ?? focusIndex
        for size in stride(from: min(visibleCount, projected.count), through: 1, by: -1) {
            let starts = max(0, focusIndex - size + 1) ... min(focusIndex, projected.count - size)
            let fitting = starts.filter { start in
                minimums[start ..< start + size].reduce(0, +) + CGFloat(size + 1) * context.gaps <= span + tolerance
            }
            if let start = fitting.min(by: { abs($0 - viewStart) < abs($1 - viewStart) }) {
                return Array(projected[start ..< start + size])
            }
        }
        return nil
    }

    private func autoFitExcess(
        _ run: [NiriProjectedColumn],
        usingFittedSpans: Bool,
        context: NiriInteractionContext
    ) -> CGFloat {
        let span = context.orientation == .horizontal ? context.workingFrame.width : context.workingFrame.height
        let used = run.reduce(CGFloat(0)) { total, column in
            let fitted = context.orientation == .horizontal ? column.column.fittedWidth : column.column.fittedHeight
            if usingFittedSpans, let fitted { return total + fitted }
            return total + constrainedProjectedPrimarySpan(
                rawProjectedPrimarySpan(
                    for: column,
                    workingFrame: context.workingFrame,
                    gap: context.gaps,
                    orientation: context.orientation
                ),
                for: column,
                workingFrame: context.workingFrame,
                gap: context.gaps,
                orientation: context.orientation
            )
        }
        return used + CGFloat(run.count + 1) * context.gaps - span
    }

    private func isFullSpan(_ column: NiriContainer, context: NiriInteractionContext) -> Bool {
        context.orientation == .horizontal ? column.isFullWidth : column.isFullHeight
    }
}

struct NiriAutoFitBasis: Equatable {
    let geometry: NiriShrinkToFitGeometry
    let visibleCount: Int
    let columnCount: Int
}
