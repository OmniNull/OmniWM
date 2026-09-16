// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func focusTarget(
        direction: Direction,
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriNode? {
        assertSanctionedMutation()
        if direction.primaryStep(for: context.orientation) != nil {
            return moveSelectionCrossContainer(
                direction: direction,
                currentSelection: currentSelection,
                context: context,
                state: &state,
                orientation: context.orientation
            )
        }

        let target = moveSelectionWithinContainer(
            direction: direction,
            currentSelection: currentSelection,
            orientation: context.orientation,
            workspaceId: context.workspaceId
        )

        if let target {
            ensureSelectionVisible(
                node: target,
                context: context,
                state: &state
            )
        }
        return target
    }

    private func focusCombined(
        verticalDirection: Direction,
        horizontalDirection: Direction,
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState,
        targetRowIndex: Int? = nil
    ) -> NiriNode? {
        if let target = moveSelectionVertical(
            direction: verticalDirection,
            currentSelection: currentSelection,
            in: context.workspaceId
        ) {
            ensureSelectionVisible(
                node: target,
                context: context,
                state: &state
            )
            return target
        }

        return moveSelectionHorizontal(
            direction: horizontalDirection,
            currentSelection: currentSelection,
            context: context,
            state: &state,
            targetRowIndex: targetRowIndex
        )
    }

    func focusDownOrLeft(
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriNode? {
        assertSanctionedMutation()
        return focusCombined(
            verticalDirection: .down,
            horizontalDirection: .left,
            currentSelection: currentSelection,
            context: context,
            state: &state,
            targetRowIndex: Int.max
        )
    }

    func focusUpOrRight(
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriNode? {
        assertSanctionedMutation()
        return focusCombined(
            verticalDirection: .up,
            horizontalDirection: .right,
            currentSelection: currentSelection,
            context: context,
            state: &state
        )
    }

    private func focusColumnByIndex(
        _ targetIndex: Int,
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriNode? {
        let columns = projectedColumns(in: context.workspaceId)
        guard columns.indices.contains(targetIndex) else { return nil }

        if let currentWindow = currentSelection as? NiriWindow,
           !isExcludedFromProjection(currentWindow.token, in: context.workspaceId),
           let currentColumn = column(of: currentSelection)
        {
            updateActiveTileIdx(for: currentSelection.id, in: currentColumn)
        }

        state.activatePrevColumnOnRemoval = nil

        let targetColumn = columns[targetIndex]
        let windows = targetColumn.windows
        guard !windows.isEmpty else { return nil }

        let target = projectedActiveWindow(in: targetColumn) ?? windows[0]
        ensureSelectionVisible(
            node: target,
            context: context,
            state: &state
        )
        return target
    }

    func focusColumnFirst(
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriNode? {
        assertSanctionedMutation()
        return focusColumnByIndex(
            0,
            currentSelection: currentSelection,
            context: context,
            state: &state
        )
    }

    func focusColumnLast(
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriNode? {
        assertSanctionedMutation()
        let columns = projectedColumns(in: context.workspaceId)
        guard !columns.isEmpty else { return nil }
        return focusColumnByIndex(
            columns.count - 1,
            currentSelection: currentSelection,
            context: context,
            state: &state
        )
    }

    func focusColumn(
        _ columnIndex: Int,
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriNode? {
        assertSanctionedMutation()
        return focusColumnByIndex(
            columnIndex,
            currentSelection: currentSelection,
            context: context,
            state: &state
        )
    }

    func focusWindowInColumn(
        _ windowIndex: Int,
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriNode? {
        assertSanctionedMutation()
        return focusWindowAtNiriIndex(
            windowIndex,
            currentSelection: currentSelection,
            context: context,
            state: &state
        )
    }

    func focusWindowTop(
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriNode? {
        assertSanctionedMutation()
        return focusWindowAtVisualIndex(
            0,
            currentSelection: currentSelection,
            context: context,
            state: &state
        )
    }

    func focusWindowBottom(
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriNode? {
        assertSanctionedMutation()
        return focusWindowAtVisualIndex(
            Int.max,
            currentSelection: currentSelection,
            context: context,
            state: &state
        )
    }

    func focusWindowDownOrTop(
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriNode? {
        assertSanctionedMutation()
        if context.orientation == .vertical {
            if let target = moveSelectionCrossContainer(
                direction: .down,
                currentSelection: currentSelection,
                context: context,
                state: &state,
                orientation: context.orientation
            ) {
                return target
            }

            return focusColumnLast(
                currentSelection: currentSelection,
                context: context,
                state: &state
            )
        }

        if let target = moveSelectionVertical(
            direction: .down,
            currentSelection: currentSelection,
            in: context.workspaceId
        ) {
            ensureSelectionVisible(
                node: target,
                context: context,
                state: &state
            )
            return target
        }

        return focusWindowTop(
            currentSelection: currentSelection,
            context: context,
            state: &state
        )
    }

    func focusWindowUpOrBottom(
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriNode? {
        assertSanctionedMutation()
        if context.orientation == .vertical {
            if let target = moveSelectionCrossContainer(
                direction: .up,
                currentSelection: currentSelection,
                context: context,
                state: &state,
                orientation: context.orientation
            ) {
                return target
            }

            return focusColumnFirst(
                currentSelection: currentSelection,
                context: context,
                state: &state
            )
        }

        if let target = moveSelectionVertical(
            direction: .up,
            currentSelection: currentSelection,
            in: context.workspaceId
        ) {
            ensureSelectionVisible(
                node: target,
                context: context,
                state: &state
            )
            return target
        }

        return focusWindowBottom(
            currentSelection: currentSelection,
            context: context,
            state: &state
        )
    }

    private func focusWindowAtNiriIndex(
        _ oneBasedWindowIndex: Int,
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriNode? {
        let visualIndex = oneBasedWindowIndex <= 1 ? 0 : oneBasedWindowIndex - 1
        return focusWindowAtVisualIndex(
            visualIndex,
            currentSelection: currentSelection,
            context: context,
            state: &state
        )
    }

    private func focusWindowAtVisualIndex(
        _ visualIndex: Int,
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriNode? {
        guard let currentColumn = column(of: currentSelection) else { return nil }

        let windows = projectedWindows(in: currentColumn, workspaceId: context.workspaceId)
        guard !windows.isEmpty else { return nil }

        let clampedVisualIndex = min(max(visualIndex, 0), windows.count - 1)
        let projectedStorageIndex = windows.count - 1 - clampedVisualIndex
        let target = windows[projectedStorageIndex]
        guard let durableStorageIndex = currentColumn.windowNodes.firstIndex(where: { $0 === target }) else {
            return nil
        }
        currentColumn.setActiveTileIdx(durableStorageIndex)
        if currentColumn.isTabbed {
            updateTabbedColumnVisibility(column: currentColumn)
        }

        ensureSelectionVisible(
            node: target,
            context: context,
            state: &state
        )
        return target
    }

    func focusPrevious(
        currentNodeId: NodeId?,
        context: NiriInteractionContext,
        state: inout ViewportState,
        limitToWorkspace: Bool = true
    ) -> NiriWindow? {
        assertSanctionedMutation()
        let searchWorkspaceId = limitToWorkspace ? context.workspaceId : nil
        guard let previousWindow = findMostRecentlyFocusedWindow(
            excluding: currentNodeId,
            in: searchWorkspaceId
        ) else {
            return nil
        }

        state.activatePrevColumnOnRemoval = nil

        ensureSelectionVisible(
            node: previousWindow,
            context: context,
            state: &state
        )

        return previousWindow
    }
}
