// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    func updateActiveTileIdx(for nodeId: NodeId, in col: NiriContainer) {
        let windowNodes = col.windowNodes
        let idx = windowNodes.firstIndex(where: { $0.id == nodeId }) ?? 0
        col.setActiveTileIdx(idx)
    }

    func moveSelectionByColumns(
        steps: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        targetRowIndex: Int? = nil
    ) -> NiriNode? {
        guard steps != 0 else { return currentSelection }

        let projectedColumns = projectedColumns(in: workspaceId)
        guard !projectedColumns.isEmpty else { return nil }

        guard let currentColumn = column(of: currentSelection),
              let durableCurrentIndex = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return nil
        }

        if let currentWindow = currentSelection as? NiriWindow,
           !isExcludedFromProjection(currentWindow.token, in: workspaceId)
        {
            updateActiveTileIdx(for: currentSelection.id, in: currentColumn)
        }

        let projectedCurrentIndex = projectedColumns.firstIndex { $0.column === currentColumn }
        let targetIndex: Int
        if let projectedCurrentIndex {
            guard let wrappedIndex = wrapIndex(
                projectedCurrentIndex + steps,
                total: projectedColumns.count,
                in: workspaceId
            ) else {
                return nil
            }
            targetIndex = wrappedIndex
        } else {
            let candidates = projectedColumns.indices.filter {
                steps > 0
                    ? projectedColumns[$0].durableIndex > durableCurrentIndex
                    : projectedColumns[$0].durableIndex < durableCurrentIndex
            }
            guard let firstIndex = steps > 0 ? candidates.first : candidates.last else { return nil }
            let remainingSteps = steps > 0 ? steps - 1 : steps + 1
            guard let wrappedIndex = wrapIndex(
                firstIndex + remainingSteps,
                total: projectedColumns.count,
                in: workspaceId
            ) else {
                return nil
            }
            targetIndex = wrappedIndex
        }

        let targetColumn = projectedColumns[targetIndex]
        return projectedRow(in: targetColumn, targetRowIndex: targetRowIndex)
    }

    func moveSelectionHorizontal(
        direction: Direction,
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState,
        targetRowIndex: Int? = nil
    ) -> NiriNode? {
        moveSelectionCrossContainer(
            direction: direction,
            currentSelection: currentSelection,
            context: context,
            state: &state,
            orientation: .horizontal,
            targetSiblingIndex: targetRowIndex
        )
    }

    func moveSelectionCrossContainer(
        direction: Direction,
        currentSelection: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState,
        orientation: Monitor.Orientation,
        targetSiblingIndex: Int? = nil
    ) -> NiriNode? {
        guard let step = direction.primaryStep(for: orientation) else { return nil }

        guard let newSelection = moveSelectionByColumns(
            steps: step,
            currentSelection: currentSelection,
            in: context.workspaceId,
            targetRowIndex: targetSiblingIndex
        ) else {
            return nil
        }

        state.activatePrevColumnOnRemoval = nil

        ensureSelectionVisible(
            node: newSelection,
            context: context,
            state: &state
        )

        return newSelection
    }

    func moveSelectionVertical(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriNode? {
        moveSelectionWithinContainer(
            direction: direction,
            currentSelection: currentSelection,
            orientation: .horizontal,
            workspaceId: workspaceId
        )
    }

    func moveSelectionWithinContainer(
        direction: Direction,
        currentSelection: NiriNode,
        orientation: Monitor.Orientation,
        workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriNode? {
        guard let step = direction.secondaryStep(for: orientation) else { return nil }

        guard let container = column(of: currentSelection) else {
            return step > 0 ? currentSelection.nextSibling() : currentSelection.prevSibling()
        }

        if container.isTabbed {
            return moveSelectionWithinContainerTabbed(
                direction: direction,
                in: container,
                orientation: orientation,
                workspaceId: workspaceId
            )
        }

        let windows = workspaceId.map { projectedWindows(in: container, workspaceId: $0) }
            ?? container.windowNodes
        guard let currentWindow = currentSelection as? NiriWindow,
              let currentIndex = windows.firstIndex(where: { $0 === currentWindow })
        else {
            return step > 0 ? windows.first : windows.last
        }
        let targetIndex = currentIndex + step
        guard windows.indices.contains(targetIndex) else { return nil }
        let target = windows[targetIndex]

        if let idx = container.windowNodes.firstIndex(where: { $0 === target }) {
            container.setActiveTileIdx(idx)
        }

        return target
    }

    private func moveSelectionWithinContainerTabbed(
        direction: Direction,
        in container: NiriContainer,
        orientation: Monitor.Orientation,
        workspaceId: WorkspaceDescriptor.ID?
    ) -> NiriNode? {
        guard let step = direction.secondaryStep(for: orientation) else { return nil }

        let windows = workspaceId.map { projectedWindows(in: container, workspaceId: $0) }
            ?? container.windowNodes
        guard !windows.isEmpty else { return nil }

        let activeWindow = workspaceId.flatMap {
            projectedActiveWindow(in: container, workspaceId: $0)
        }
        let currentIdx = activeWindow.flatMap { activeWindow in
            windows.firstIndex(where: { $0 === activeWindow })
        } ?? 0
        let newIdx = currentIdx + step
        guard newIdx >= 0, newIdx < windows.count else { return nil }

        guard let durableIndex = container.windowNodes.firstIndex(where: { $0 === windows[newIdx] }) else {
            return nil
        }
        container.setActiveTileIdx(durableIndex)
        updateTabbedColumnVisibility(column: container)

        return windows[newIdx]
    }

    func ensureSelectionVisible(
        node: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil,
        previousActiveContainerPosition: CGFloat? = nil,
        previousProjectedAnchor: NiriProjectedViewportAnchor? = nil
    ) {
        assertSanctionedMutation()
        guard !isLiveColumnMoveActive(in: context.workspaceId) else { return }
        if !projectionExclusions(in: context.workspaceId).isEmpty {
            ensureProjectedSelectionVisible(
                node: node,
                context: context,
                state: &state,
                animationConfig: animationConfig,
                fromContainerIndex: fromContainerIndex,
                previousProjectedAnchor: previousProjectedAnchor
            )
            return
        }
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation,
            motion: context.motion
        )
        let containers = columns(in: context.workspaceId)
        guard !containers.isEmpty else { return }

        guard let container = column(of: node),
              let targetIdx = columnIndex(of: container, in: context.workspaceId)
        else {
            return
        }

        let prevIdx = fromContainerIndex ?? state.activeColumnIndex

        let scale = displayScale(in: context.workspaceId)
        let viewFrame = monitorForWorkspace(context.workspaceId)?.frame
        state.retargetColumn(
            to: targetIdx,
            columns: containers,
            gap: context.gaps,
            orientation: context.orientation,
            previousPosition: previousActiveContainerPosition
        )

        let settings = effectiveSettings(in: context.workspaceId)
        state.ensureContainerVisible(
            containerIndex: targetIdx,
            containers: containers,
            context: context,
            centerMode: settings.centerFocusedColumn,
            alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn,
            animationConfig: animationConfig,
            fromContainerIndex: prevIdx,
            keepsStripEndsOnScreen: keepsStripEndsOnScreen,
            scale: scale,
            viewFrame: viewFrame
        )
    }

    func resolvePrimaryContainerSpans(
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation,
        motion: MotionSnapshot? = nil
    ) {
        reconcilePrimarySpanFit(
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation,
            motion: motion
        )
        for container in columns(in: workspaceId) {
            switch orientation {
            case .horizontal where container.cachedWidth <= 0:
                container.resolveAndCacheWidth(
                    workingAreaWidth: workingFrame.width,
                    gaps: gaps,
                    contentInset: tabContentInset(for: container)
                )
            case .vertical where container.cachedHeight <= 0:
                container.resolveAndCacheHeight(workingAreaHeight: workingFrame.height, gaps: gaps)
            case .horizontal,
                 .vertical:
                break
            }
        }
    }

    private func projectedRow(in targetColumn: NiriProjectedColumn, targetRowIndex: Int?) -> NiriWindow? {
        let targetRows = targetColumn.windows
        guard !targetRows.isEmpty else {
            return nil
        }

        let activeWindow = projectedActiveWindow(in: targetColumn)
        let activeRowIndex = activeWindow.flatMap { activeWindow in
            targetRows.firstIndex(where: { $0 === activeWindow })
        } ?? 0
        let clampedRowIndex = min(targetRowIndex ?? activeRowIndex, targetRows.count - 1)
        return targetRows[clampedRowIndex]
    }
}
