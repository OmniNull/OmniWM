// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension NiriLayoutEngine {
    func consumeOrExpelWindow(
        _ window: NiriWindow,
        direction: Direction,
        context: NiriInteractionContext,
        state: inout ViewportState,
        allowEdgeWrap: Bool = true
    ) -> Bool {
        assertSanctionedMutation()
        guard direction == .left || direction == .right else { return false }
        guard !isExcludedFromProjection(window.token, in: context.workspaceId) else { return false }

        guard let currentColumn = findColumn(containing: window, in: context.workspaceId)
        else {
            return false
        }

        let visibleMembers = projectedWindows(in: currentColumn, workspaceId: context.workspaceId)
        if visibleMembers.count > 1 {
            return expelWindow(
                window,
                to: direction,
                context: context,
                state: &state
            )
        }

        let projectedColumns = projectedColumns(in: context.workspaceId)
        guard let currentIdx = projectedColumns.firstIndex(where: { $0.column === currentColumn }) else {
            return false
        }
        let step = (direction == .right) ? 1 : -1
        let neighborIdx: Int
        if allowEdgeWrap {
            guard let wrappedIdx = wrapIndex(
                currentIdx + step,
                total: projectedColumns.count,
                in: context.workspaceId
            ) else {
                return false
            }
            neighborIdx = wrappedIdx
        } else {
            let adjacentIdx = currentIdx + step
            guard projectedColumns.indices.contains(adjacentIdx) else {
                return false
            }
            neighborIdx = adjacentIdx
        }

        if neighborIdx == currentIdx { return false }

        let neighborColumn = projectedColumns[neighborIdx].column
        guard neighborColumn.id != currentColumn.id else { return false }

        return consumeWindow(
            window,
            into: neighborColumn,
            enteringFrom: direction,
            context: context,
            state: &state
        )
    }

    func columnCanAcceptTransfer(
        _ column: NiriContainer,
        adding window: NiriWindow,
        addingConstraints: WindowSizeConstraints? = nil,
        removing removedWindow: NiriWindow? = nil,
        in workspaceId: WorkspaceDescriptor.ID,
        geometry: NiriSizingGeometry
    ) -> Bool {
        let workingFrame = geometry.workingFrame
        let gaps = geometry.gaps
        let orientation = geometry.orientation
        guard !column.isTabbed else { return true }
        let axisSpace = orientation == .horizontal ? workingFrame.height : workingFrame.width
        func axisMinimum(_ constraints: WindowSizeConstraints) -> CGFloat {
            let minSize = constraints.normalized().minSize
            return orientation == .horizontal ? minSize.height : minSize.width
        }
        let remaining = projectedWindows(in: column, workspaceId: workspaceId).filter { $0 !== removedWindow }
        let minSum = remaining.reduce(axisMinimum(addingConstraints ?? window.constraints)) {
            $0 + axisMinimum($1.constraints)
        }
        let gapSum = gaps * CGFloat(remaining.count + 2)
        return minSum + gapSum <= axisSpace + 0.5
    }

    @discardableResult
    func consumeWindow(
        _ window: NiriWindow,
        into targetColumn: NiriContainer,
        enteringFrom direction: Direction,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard let source = consumptionSource(window, target: targetColumn, context: context) else { return false }
        let (currentColumn, currentIdx) = source

        let targetInsertionPolicy: TargetColumnInsertionPolicy = direction == .down ? .append : .visualBottom

        let snapshot = prepareColumnMutation(context: context)
        let cols = columns(in: context.workspaceId)
        let selectionAnchor = columnSelectionAnchor(
            state: state,
            columns: cols,
            geometry: snapshot.geometry,
            context: context
        )
        let now = animationClock?.now() ?? CACurrentMediaTime()
        let sourceSample = sampleTransferredWindow(
            window, in: (currentColumn, currentIdx), columns: cols, state: state,
            sampling: ColumnRenderSampling(geometry: snapshot.geometry, time: now, context: context)
        )

        let transfer = moveWindowToColumn(
            window,
            from: currentColumn,
            to: targetColumn,
            in: context.workspaceId,
            targetInsertionPolicy: targetInsertionPolicy,
            activateInsertedWindowInTarget: true
        )

        state.selectedNodeId = window.id

        cleanUpConsumedColumn(currentColumn, transfer: transfer, snapshot: snapshot, context: context, state: &state)

        let currentGeometry = completeColumnMutation(from: snapshot, context: context)
        animateConsumedWindow(
            window, target: (targetColumn, transfer.targetColumnIndexAfterInsert),
            sample: WindowTransferAnimationSample(
                source: sourceSample, geometry: currentGeometry, time: now, context: context
            ), state: state
        )

        ensureSelectionVisible(
            node: window,
            context: context,
            state: &state,
            fromContainerIndex: selectionAnchor.index,
            previousActiveContainerPosition: selectionAnchor.position,
            previousProjectedAnchor: selectionAnchor.projected
        )

        return true
    }

    private func consumptionSource(
        _ window: NiriWindow,
        target targetColumn: NiriContainer,
        context: NiriInteractionContext
    ) -> (NiriContainer, Int)? {
        guard let currentColumn = findColumn(containing: window, in: context.workspaceId),
              let currentIdx = columnIndex(of: currentColumn, in: context.workspaceId),
              currentColumn.id != targetColumn.id
        else {
            return nil
        }

        guard columnCanAcceptTransfer(
            targetColumn,
            adding: window,
            in: context.workspaceId,
            geometry: context.sizingGeometry
        ) else {
            return nil
        }

        return (currentColumn, currentIdx)
    }

    private struct ColumnSelectionAnchor {
        let index: Int
        let position: CGFloat
        let projected: NiriProjectedViewportAnchor?
    }

    private func columnSelectionAnchor(
        state: ViewportState,
        columns: [NiriContainer],
        geometry: NiriProjectedGeometrySnapshot,
        context: NiriInteractionContext
    ) -> ColumnSelectionAnchor {
        let projected = projectedViewportAnchor(state: state, geometry: geometry, in: context.workspaceId)
        let index = state.activeColumnIndex
        let position = state.containerPosition(
            at: index, containers: columns, gap: context.gaps,
            sizeKeyPath: primarySizeKeyPath(for: context.orientation)
        )
        return ColumnSelectionAnchor(index: index, position: position, projected: projected)
    }

    func consumeWindowIntoColumn(
        focusedColumn targetColumn: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        let projectedColumns = projectedColumns(in: context.workspaceId)
        guard let targetProjectedIndex = projectedColumns.firstIndex(where: { $0.column === targetColumn }),
              projectedColumns.indices.contains(targetProjectedIndex + 1)
        else {
            return false
        }

        let sourceProjectedColumn = projectedColumns[targetProjectedIndex + 1]
        let sourceColumn = sourceProjectedColumn.column
        let sourceColumnIdx = sourceProjectedColumn.durableIndex
        let targetColumnIdx = projectedColumns[targetProjectedIndex].durableIndex
        let cols = columns(in: context.workspaceId)
        guard let window = sourceProjectedColumn.windows.last else {
            return false
        }

        guard columnCanAcceptTransfer(
            targetColumn,
            adding: window,
            in: context.workspaceId,
            geometry: context.sizingGeometry
        ) else {
            return false
        }

        let snapshot = prepareColumnMutation(context: context)
        let now = animationClock?.now() ?? CACurrentMediaTime()
        let sourceSample = sampleTransferredWindow(
            window, in: (sourceColumn, sourceColumnIdx), columns: cols, state: state,
            sampling: ColumnRenderSampling(geometry: snapshot.geometry, time: now, context: context)
        )

        let transfer = moveWindowToColumn(
            window,
            from: sourceColumn,
            to: targetColumn,
            in: context.workspaceId,
            targetInsertionPolicy: .visualBottom
        )

        cleanUpConsumedColumn(sourceColumn, transfer: transfer, snapshot: snapshot, context: context, state: &state)

        let currentGeometry = completeColumnMutation(from: snapshot, context: context)
        animateConsumedWindow(
            window, target: (targetColumn, targetColumnIdx),
            sample: WindowTransferAnimationSample(
                source: sourceSample, geometry: currentGeometry, time: now, context: context
            ), state: state
        )

        return true
    }
}
