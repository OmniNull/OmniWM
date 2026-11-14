// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

extension NiriLayoutEngine {
    func autoFitVisibleColumns(context: NiriInteractionContext, state: inout ViewportState) {
        assertSanctionedMutation()
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation,
            motion: context.motion
        )
        let all = projectedColumns(in: context.workspaceId)
        let projected = all.contains { $0.windows.isEmpty } ? all.filter { !$0.windows.isEmpty } : all
        let visibleCount = effectiveVisibleContainerCount(in: context.workspaceId)
        let workspace = ensureState(for: context.workspaceId)
        let sizesChanged = updateAutoFitSignature(
            of: workspace,
            projected,
            visibleCount: visibleCount,
            context: context
        )
        guard !all.isEmpty, !autoFitPaused(workspace, state: state) else {
            workspace.autoFitChangePending = false
            return
        }
        let active = all[projectedActiveColumnIndex(state: state, columns: all, in: context.workspaceId)].column
        let changed = autoFitChange(sizesChanged, active: active, in: workspace)
        guard let focusIndex = projected.firstIndex(where: { $0.column === active }) else { return }
        let window = autoFitWindow(
            projected,
            viewStart: autoFitViewStart(projected, all: all, context: context, state: state) ?? focusIndex,
            focusIndex: focusIndex,
            visibleCount: visibleCount,
            context: context
        )
        guard !window.isEmpty, !window.contains(where: { autoFitIsFullSpan($0.column, context: context) }) else {
            return
        }
        let wantsFullCount = window.count == min(visibleCount, projected.count)
        guard autoFitNeeded(window, wantsFullCount: wantsFullCount, context: context) else {
            guard wantsFullCount,
                  window.count > 1,
                  autoFitFills(window, context: context),
                  effectiveSettings(in: context.workspaceId).centerFocusedColumn != .always
            else { return }
            alignViewport(toFirstOf: window, context: context, state: &state)
            return
        }
        guard changed else { return }
        fit(window, around: projected[focusIndex].column, columnCount: projected.count, context: context, state: &state)
        workspace.autoFitChangePending = false
        _ = updateAutoFitSignature(of: workspace, projected, visibleCount: visibleCount, context: context)
    }

    private func autoFitChange(_ sizesChanged: Bool, active: NiriContainer, in workspace: NiriWorkspaceState) -> Bool {
        let activeMoved = workspace.autoFitActiveColumnId != active.id
        workspace.autoFitActiveColumnId = active.id
        let changed = sizesChanged || workspace.autoFitChangePending
        workspace.autoFitChangePending = changed && activeMoved
        return changed
    }

    private func autoFitPaused(_ workspace: NiriWorkspaceState, state: ViewportState) -> Bool {
        let endingMouseResize = workspace.autoFitSkipsMouseResize
        workspace.autoFitSkipsMouseResize = interactiveResize != nil
        return interactiveResize != nil
            || endingMouseResize
            || state.preservesGestureOffset
            || state.offsetTransition.kind == .deceleration
    }

    private func fit(
        _ window: [NiriProjectedColumn],
        around focused: NiriContainer,
        columnCount: Int,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let workspace = ensureState(for: context.workspaceId)
        switch context.orientation {
        case .horizontal: workspace.manualWidthColumnCount = columnCount
        case .vertical: workspace.manualHeightColumnCount = columnCount
        }
        if window.count > 1 {
            shrinkVisibleColumnsToFit(around: focused, onScreen: window, context: context, state: &state)
        } else {
            alignViewport(toFirstOf: window, context: context, state: &state)
        }
    }

    private func updateAutoFitSignature(
        of workspace: NiriWorkspaceState,
        _ projected: [NiriProjectedColumn],
        visibleCount: Int,
        context: NiriInteractionContext
    ) -> Bool {
        guard !autoFitSignature(workspace.autoFitSignature, matches: projected, visibleCount, context) else {
            return false
        }
        let previous = workspace.autoFitSignature
        let signature = NiriAutoFitSignature(
            columnIds: projected.map(\.column.id),
            spans: projected.map { $0.column[keyPath: context.orientation.settledSpanKeyPath] },
            fullSpans: projected.map { autoFitIsFullSpan($0.column, context: context) },
            minimums: projected.map { autoFitMinimum(of: $0, context: context) },
            visibleCount: visibleCount,
            workingFrame: context.workingFrame,
            gaps: context.gaps
        )
        workspace.autoFitSignature = signature
        return previous.map { $0.columnIds != signature.columnIds || $0.fullSpans == signature.fullSpans } ?? true
    }

    private func autoFitSignature(
        _ signature: NiriAutoFitSignature?,
        matches projected: [NiriProjectedColumn],
        _ visibleCount: Int,
        _ context: NiriInteractionContext
    ) -> Bool {
        guard let signature,
              signature.visibleCount == visibleCount,
              signature.workingFrame == context.workingFrame,
              signature.gaps == context.gaps,
              signature.columnIds.count == projected.count
        else { return false }
        for index in projected.indices {
            guard signature.columnIds[index] == projected[index].column.id,
                  signature.spans[index] == projected[index].column[keyPath: context.orientation.settledSpanKeyPath],
                  signature.fullSpans[index] == autoFitIsFullSpan(projected[index].column, context: context),
                  signature.minimums[index] == autoFitMinimum(of: projected[index], context: context)
            else { return false }
        }
        return true
    }

    private func autoFitIsFullSpan(_ column: NiriContainer, context: NiriInteractionContext) -> Bool {
        context.orientation == .horizontal ? column.isFullWidth : column.isFullHeight
    }

    private func autoFitMinimum(of column: NiriProjectedColumn, context: NiriInteractionContext) -> CGFloat {
        constrainedProjectedPrimarySpan(
            0, for: column, workingFrame: context.workingFrame, gap: context.gaps, orientation: context.orientation
        )
    }

    private func autoFitViewStart(
        _ projected: [NiriProjectedColumn],
        all: [NiriProjectedColumn],
        context: NiriInteractionContext,
        state: ViewportState
    ) -> Int? {
        let relations = viewportRelations(
            of: all,
            in: context.workspaceId,
            state: state,
            geometry: context.sizingGeometry
        )
        guard let first = all.indices.first(where: { relations[$0] == .intersecting && !all[$0].windows.isEmpty })
        else { return nil }
        return projected.firstIndex { $0.column === all[first].column }
    }

    private func autoFitWindow(
        _ projected: [NiriProjectedColumn],
        viewStart: Int,
        focusIndex: Int,
        visibleCount: Int,
        context: NiriInteractionContext
    ) -> [NiriProjectedColumn] {
        let span = context.orientation == .horizontal ? context.workingFrame.width : context.workingFrame.height
        let tolerance = 1 / displayScale(in: context.workspaceId)
        for size in stride(from: min(visibleCount, projected.count), through: 1, by: -1) {
            let start = min(max(viewStart, focusIndex - size + 1), focusIndex, projected.count - size)
            let window = Array(projected[start ..< start + size])
            let minimums = window.reduce(CGFloat(0)) { $0 + autoFitMinimum(of: $1, context: context) }
            if minimums + CGFloat(size + 1) * context.gaps <= span + tolerance {
                return window
            }
        }
        return []
    }

    private func autoFitNeeded(
        _ window: [NiriProjectedColumn],
        wantsFullCount: Bool,
        context: NiriInteractionContext
    ) -> Bool {
        let excess = autoFitExcess(window, context: context)
        let tolerance = 1 / displayScale(in: context.workspaceId)
        return wantsFullCount ? excess > tolerance : abs(excess) > tolerance
    }

    private func autoFitFills(_ window: [NiriProjectedColumn], context: NiriInteractionContext) -> Bool {
        abs(autoFitExcess(window, context: context)) <= 1 / displayScale(in: context.workspaceId)
    }

    private func autoFitExcess(_ window: [NiriProjectedColumn], context: NiriInteractionContext) -> CGFloat {
        let keyPath = context.orientation.settledSpanKeyPath
        let span = context.orientation == .horizontal ? context.workingFrame.width : context.workingFrame.height
        return window.reduce(CGFloat(0)) { $0 + $1.column[keyPath: keyPath] }
            + CGFloat(window.count + 1) * context.gaps - span
    }
}

struct NiriAutoFitSignature: Equatable {
    let columnIds: [NodeId]
    let spans: [CGFloat]
    let fullSpans: [Bool]
    let minimums: [CGFloat]
    let visibleCount: Int
    let workingFrame: CGRect
    let gaps: CGFloat
}
