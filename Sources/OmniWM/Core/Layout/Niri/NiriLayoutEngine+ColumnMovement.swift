// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

enum NiriColumnMoveTarget: Equatable {
    case direction(Direction)
    case first
    case last
    case index(Int)
}

extension NiriLayoutEngine {
    func moveColumn(
        _ column: NiriContainer,
        direction: Direction,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        moveColumn(column, target: .direction(direction), context: context, state: &state)
    }

    func moveColumnToFirst(
        _ column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        moveColumn(column, target: .first, context: context, state: &state)
    }

    func moveColumnToLast(
        _ column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        moveColumn(column, target: .last, context: context, state: &state)
    }

    func moveColumnToIndex(
        _ column: NiriContainer,
        _ oneBasedIndex: Int,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        moveColumn(column, target: .index(oneBasedIndex), context: context, state: &state)
    }

    func moveColumn(
        _ column: NiriContainer,
        target: NiriColumnMoveTarget,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard let targetIdx = durableMoveTargetIndex(for: column, target: target, context: context) else {
            return false
        }
        return moveColumn(
            column,
            to: targetIdx,
            context: context,
            state: &state
        )
    }

    func moveColumnPreservingFocus(
        _ column: NiriContainer,
        target: NiriColumnMoveTarget,
        focused: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        if column === focused {
            return moveColumn(column, target: target, context: context, state: &state)
        }
        guard let targetIdx = durableMoveTargetIndex(for: column, target: target, context: context),
              let currentIdx = columnIndex(of: column, in: context.workspaceId),
              targetIdx != currentIdx,
              let root = root(for: context.workspaceId)
        else { return false }

        let previousPositions = primaryPositions(context: context, state: state)
        cancelInteractiveResizeForMovedColumn(column, in: context.workspaceId)
        root.insertChild(column, at: targetIdx)
        if let focusedIdx = columnIndex(of: focused, in: context.workspaceId) {
            state.activeColumnIndex = focusedIdx
        }
        state.activatePrevColumnOnRemoval = nil
        state.viewOffsetToRestore = nil
        let currentPositions = primaryPositions(context: context, state: state)

        if let previousFocused = previousPositions[focused.id], let currentFocused = currentPositions[focused.id] {
            let focusedShift = currentFocused - previousFocused
            for movedColumn in columns(in: context.workspaceId) {
                guard let previous = previousPositions[movedColumn.id],
                      let current = currentPositions[movedColumn.id]
                else { continue }
                let displacement = previous - current + focusedShift
                guard abs(displacement) > 0.001 else { continue }
                animateReorderedColumn(movedColumn, displacement: displacement, context: context)
            }
        }
        return true
    }

    private func durableMoveTargetIndex(
        for column: NiriContainer,
        target: NiriColumnMoveTarget,
        context: NiriInteractionContext
    ) -> Int? {
        let projectedColumns = projectedColumns(in: context.workspaceId)
        guard let currentProjectedIndex = projectedColumns.firstIndex(where: { $0.column === column }) else {
            return nil
        }
        let targetProjectedIndex: Int
        switch target {
        case let .direction(direction):
            guard let step = direction.primaryStep(for: context.orientation) else { return nil }
            targetProjectedIndex = currentProjectedIndex + step
        case .first:
            targetProjectedIndex = 0
        case .last:
            targetProjectedIndex = projectedColumns.count - 1
        case let .index(oneBasedIndex):
            targetProjectedIndex = min(oneBasedIndex <= 1 ? 0 : oneBasedIndex - 1, projectedColumns.count - 1)
        }
        guard projectedColumns.indices.contains(targetProjectedIndex) else { return nil }
        return projectedColumns[targetProjectedIndex].durableIndex
    }

    private func primaryPositions(
        context: NiriInteractionContext,
        state: ViewportState
    ) -> [NodeId: CGFloat] {
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        if !projectionExclusions(in: context.workspaceId).isEmpty {
            let geometry = projectedGeometrySnapshot(
                in: context.workspaceId,
                workingFrame: context.workingFrame,
                gaps: context.gaps,
                orientation: context.orientation
            )
            return Dictionary(
                uniqueKeysWithValues: geometry.columns.map { ($0.projectedColumn.column.id, $0.primaryPosition) }
            )
        }
        let cols = columns(in: context.workspaceId)
        let sizeKeyPath = primarySizeKeyPath(for: context.orientation)
        return Dictionary(uniqueKeysWithValues: cols.indices.map { index in
            (
                cols[index].id,
                state.containerPosition(at: index, containers: cols, gap: context.gaps, sizeKeyPath: sizeKeyPath)
            )
        })
    }

    private func moveColumn(
        _ column: NiriContainer,
        to targetIdx: Int,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        let cols = columns(in: context.workspaceId)
        guard let currentIdx = columnIndex(of: column, in: context.workspaceId),
              cols.indices.contains(targetIdx)
        else { return false }
        if targetIdx == currentIdx { return false }

        let snapshot = columnReorderSnapshot(
            column,
            currentIdx: currentIdx,
            columns: cols,
            context: context,
            state: state
        )
        guard let root = root(for: context.workspaceId) else { return false }
        cancelInteractiveResizeForMovedColumn(column, in: context.workspaceId)
        root.insertChild(column, at: targetIdx)

        animateColumnReorder(column, from: snapshot, to: targetIdx, context: context, state: &state)

        ensureColumnVisible(
            column,
            context: context,
            state: &state,
            animationConfig: windowMovementAnimationConfig,
            fromContainerIndex: currentIdx,
            previousProjectedAnchor: snapshot.projectedAnchor
        )

        return true
    }

    private struct ColumnReorderSnapshot {
        let index: Int
        let position: CGFloat
        let nextPosition: CGFloat
        let geometry: NiriProjectedGeometrySnapshot?
        let projectedAnchor: NiriProjectedViewportAnchor?
    }

    private func columnReorderSnapshot(
        _ column: NiriContainer,
        currentIdx: Int,
        columns cols: [NiriContainer],
        context: NiriInteractionContext,
        state: ViewportState
    ) -> ColumnReorderSnapshot {
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let previousGeometry = if projectionExclusions(in: context.workspaceId).isEmpty {
            Optional<NiriProjectedGeometrySnapshot>.none
        } else {
            projectedGeometrySnapshot(
                in: context.workspaceId,
                workingFrame: context.workingFrame,
                gaps: context.gaps,
                orientation: context.orientation
            )
        }
        let previousProjectedAnchor = previousGeometry.flatMap {
            projectedViewportAnchor(state: state, geometry: $0, in: context.workspaceId)
        }
        let sizeKeyPath = primarySizeKeyPath(for: context.orientation)
        let currentPosition = state.containerPosition(
            at: currentIdx,
            containers: cols,
            gap: context.gaps,
            sizeKeyPath: sizeKeyPath
        )
        let nextPosition = currentIdx + 1 < cols.count
            ? state.containerPosition(
                at: currentIdx + 1,
                containers: cols,
                gap: context.gaps,
                sizeKeyPath: sizeKeyPath
            )
            : currentPosition + (
                column[keyPath: sizeKeyPath] > 0
                    ? column[keyPath: sizeKeyPath]
                    : (context.orientation == .horizontal ? context.workingFrame.width : context.workingFrame.height)
                    / CGFloat(effectiveVisibleContainerCount(in: context.workspaceId))
            ) + context.gaps

        return ColumnReorderSnapshot(
            index: currentIdx, position: currentPosition, nextPosition: nextPosition,
            geometry: previousGeometry, projectedAnchor: previousProjectedAnchor
        )
    }

    private func animateColumnReorder(
        _ column: NiriContainer,
        from snapshot: ColumnReorderSnapshot,
        to targetIdx: Int,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        if let previousGeometry = snapshot.geometry {
            let currentGeometry = projectedGeometrySnapshot(
                in: context.workspaceId, workingFrame: context.workingFrame,
                gaps: context.gaps, orientation: context.orientation
            )
            animateProjectedColumns(
                from: previousGeometry, to: currentGeometry, in: context.workspaceId,
                motion: context.motion, orientation: context.orientation
            )
        } else {
            animateDurableColumnReorder(column, from: snapshot, to: targetIdx, context: context, state: &state)
        }
    }

    private func animateDurableColumnReorder(
        _ column: NiriContainer,
        from snapshot: ColumnReorderSnapshot,
        to targetIdx: Int,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let newCols = columns(in: context.workspaceId)
        let sizeKeyPath = primarySizeKeyPath(for: context.orientation)
        let positionAtOldIndex = state.containerPosition(
            at: snapshot.index, containers: newCols, gap: context.gaps, sizeKeyPath: sizeKeyPath
        )
        state.offsetViewport(by: snapshot.position - positionAtOldIndex)
        let newPosition = state.containerPosition(
            at: targetIdx, containers: newCols, gap: context.gaps, sizeKeyPath: sizeKeyPath
        )
        animateReorderedColumn(column, displacement: snapshot.position - newPosition, context: context)
        let othersOffset = snapshot.nextPosition - snapshot.position
        let affectedIndices = snapshot.index < targetIdx ? snapshot
            .index ..< targetIdx : (targetIdx + 1) ..< (snapshot.index + 1)
        let displacement = snapshot.index < targetIdx ? othersOffset : -othersOffset
        for index in affectedIndices where newCols[index].id != column.id {
            animateReorderedColumn(newCols[index], displacement: displacement, context: context)
        }
    }

    private func animateReorderedColumn(
        _ column: NiriContainer,
        displacement: CGFloat,
        context: NiriInteractionContext
    ) {
        column.animateMoveFrom(
            displacement: primaryDisplacement(displacement, orientation: context.orientation),
            clock: animationClock, config: context.motion.scaled(windowMovementAnimationConfig),
            displayRefreshRate: displayRefreshRate(in: context.workspaceId),
            animated: context.motion.animationsEnabled
        )
    }

    private func cancelInteractiveResizeForMovedColumn(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let resize = interactiveResize, resize.workspaceId == workspaceId else { return }
        guard let resizeWindow = findNode(by: resize.windowId, in: workspaceId) as? NiriWindow,
              let resizeColumn = findColumn(containing: resizeWindow, in: workspaceId),
              resizeColumn === column
        else {
            return
        }

        clearInteractiveResize()
    }
}
