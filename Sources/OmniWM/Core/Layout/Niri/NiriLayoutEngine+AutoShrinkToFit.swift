// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

extension NiriLayoutEngine {
    func requestAutoFit(in workspaceId: WorkspaceDescriptor.ID) {
        guard shrinkToFit else { return }
        ensureState(for: workspaceId).autoFitRequested = true
    }

    func autoFitIfRequested(context: NiriInteractionContext, state: inout ViewportState) {
        assertSanctionedMutation()
        let workspace = ensureState(for: context.workspaceId)
        let columns = projectedColumns(in: context.workspaceId)
        let basis = autoFitBasis(columnCount: columns.count { !$0.windows.isEmpty }, context: context)
        let basisChanged = workspace.autoFitBasis.map { $0 != basis } ?? false
        if workspace.autoFitBasis != basis {
            workspace.autoFitBasis = basis
            workspace.autoFitRequested = true
        }
        guard workspace.autoFitRequested, !autoFitPaused(in: context.workspaceId, state: state) else { return }
        workspace.autoFitRequested = false

        let projected = columns.filter { !$0.windows.isEmpty }
        guard !projected.isEmpty else { return }
        let active = projected[projectedActiveColumnIndex(state: state, columns: projected, in: context.workspaceId)]
        guard let focusIndex = projected.firstIndex(where: { $0.column === active.column }),
              let run = autoFitRun(
                  projected,
                  focusIndex: focusIndex,
                  visibleCount: basis.visibleCount,
                  context: context,
                  state: state
              ),
              !run.contains(where: { isFullSpan($0.column, context: context) })
        else { return }

        let excess = autoFitExcess(run, usingFittedSpans: !basisChanged, context: context)
        let tolerance = 1 / displayScale(in: context.workspaceId)
        let fullRun = run.count == min(basis.visibleCount, projected.count)
        if excess > tolerance || (!fullRun && abs(excess) > tolerance) {
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

    private func autoFitBasis(columnCount: Int, context: NiriInteractionContext) -> NiriAutoFitBasis {
        NiriAutoFitBasis(
            geometry: NiriShrinkToFitGeometry(
                context.workingFrame,
                gaps: context.gaps,
                orientation: context.orientation
            ),
            visibleCount: effectiveVisibleContainerCount(in: context.workspaceId),
            columnCount: columnCount
        )
    }

    private func autoFitPaused(in workspaceId: WorkspaceDescriptor.ID, state: ViewportState) -> Bool {
        interactiveResize?.workspaceId == workspaceId
            || state.preservesGestureOffset
            || state.offsetTransition.kind == .deceleration
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
