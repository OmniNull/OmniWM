// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct NiriProjectedColumn {
    let column: NiriContainer
    let windows: [NiriWindow]
    let durableIndex: Int
}

extension NiriLayoutEngine {
    func setProjectionExclusions(
        _ excludedTokens: Set<WindowToken>,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard isMutationSanctioned else {
            assert(
                projectionExclusions(in: workspaceId) == excludedTokens,
                "Niri projection exclusions changed outside a sanctioned WorldStore scope"
            )
            return
        }
        let exclusionsChanged = projectionExclusions(in: workspaceId) != excludedTokens
        if excludedTokens.isEmpty {
            excludedTokensByWorkspace.removeValue(forKey: workspaceId)
        } else {
            excludedTokensByWorkspace[workspaceId] = excludedTokens
        }
        guard let root = root(for: workspaceId) else { return }
        if exclusionsChanged {
            for column in root.columns {
                column.invalidateAxisSolveInputs()
            }
        }
        for window in root.allWindows where excludedTokens.contains(window.token) {
            window.frame = nil
            window.renderedFrame = nil
        }
    }

    func clearExcludedColumnFrames(
        in workspaceId: WorkspaceDescriptor.ID,
        excluding excludedTokens: Set<WindowToken>
    ) {
        if !excludedTokens.isEmpty {
            for column in columns(in: workspaceId)
                where column.windowNodes.allSatisfy({ excludedTokens.contains($0.token) })
            {
                column.frame = nil
                column.renderedFrame = nil
            }
        }
    }

    func projectionExclusions(in workspaceId: WorkspaceDescriptor.ID) -> Set<WindowToken> {
        excludedTokensByWorkspace[workspaceId] ?? []
    }

    func isExcludedFromProjection(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        excludedTokensByWorkspace[workspaceId]?.contains(token) == true
    }

    func projectedWindows(
        in column: NiriContainer,
        workspaceId: WorkspaceDescriptor.ID
    ) -> [NiriWindow] {
        guard let excludedTokens = excludedTokensByWorkspace[workspaceId], !excludedTokens.isEmpty else {
            return column.windowNodes
        }
        return column.windowNodes.filter { !excludedTokens.contains($0.token) }
    }

    func projectedColumns(in workspaceId: WorkspaceDescriptor.ID) -> [NiriProjectedColumn] {
        guard let excludedTokens = excludedTokensByWorkspace[workspaceId], !excludedTokens.isEmpty else {
            return root(for: workspaceId)?.projectedColumns ?? []
        }
        let columns = columns(in: workspaceId)
        var projected: [NiriProjectedColumn] = []
        projected.reserveCapacity(columns.count)
        for (durableIndex, column) in columns.enumerated() {
            let windows = column.windowNodes.filter { !excludedTokens.contains($0.token) }
            if !windows.isEmpty {
                projected.append(
                    NiriProjectedColumn(column: column, windows: windows, durableIndex: durableIndex)
                )
            }
        }
        return projected
    }

    func projectedActiveWindow(in projectedColumn: NiriProjectedColumn) -> NiriWindow? {
        let windows = projectedColumn.windows
        guard !windows.isEmpty else { return nil }
        let durableWindows = projectedColumn.column.windowNodes
        guard !durableWindows.isEmpty else { return windows.first }
        let durableActiveIndex = projectedColumn.column.activeTileIdx.clamped(to: 0 ... durableWindows.count - 1)
        let durableActiveWindow = durableWindows[durableActiveIndex]
        if windows.contains(where: { $0 === durableActiveWindow }) {
            return durableActiveWindow
        }
        return windows.min { lhs, rhs in
            let lhsIndex = durableWindows.firstIndex(where: { $0 === lhs }) ?? 0
            let rhsIndex = durableWindows.firstIndex(where: { $0 === rhs }) ?? 0
            let lhsDistance = abs(lhsIndex - durableActiveIndex)
            let rhsDistance = abs(rhsIndex - durableActiveIndex)
            return lhsDistance == rhsDistance ? lhsIndex < rhsIndex : lhsDistance < rhsDistance
        }
    }

    func projectedActiveWindow(
        in column: NiriContainer,
        workspaceId: WorkspaceDescriptor.ID
    ) -> NiriWindow? {
        let windows = projectedWindows(in: column, workspaceId: workspaceId)
        guard let durableIndex = columnIndex(of: column, in: workspaceId) else { return nil }
        return projectedActiveWindow(
            in: NiriProjectedColumn(
                column: column,
                windows: windows,
                durableIndex: durableIndex
            )
        )
    }

    func isProjectedFocusableWindow(
        _ window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard !isExcludedFromProjection(window.token, in: workspaceId) else { return false }
        guard let column = column(of: window) else { return false }
        guard column.displayMode == .tabbed else { return true }
        return projectedActiveWindow(in: column, workspaceId: workspaceId) === window
    }

    func projectedActiveColumnIndex(
        state: ViewportState,
        columns projectedColumns: [NiriProjectedColumn],
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Int {
        guard !projectedColumns.isEmpty else { return 0 }

        let durableIndex = state.activeColumnIndex
        if let exactIndex = projectedColumns.firstIndex(where: { $0.durableIndex == durableIndex }) {
            return exactIndex
        }

        if let selectedNodeId = state.selectedNodeId,
           let selectedWindow = findNode(by: selectedNodeId, in: workspaceId) as? NiriWindow,
           !isExcludedFromProjection(selectedWindow.token, in: workspaceId),
           let selectedColumn = column(of: selectedWindow),
           let projectedIndex = projectedColumns.firstIndex(where: { $0.column === selectedColumn })
        {
            return projectedIndex
        }

        return projectedColumns.indices.min { lhs, rhs in
            let lhsDistance = abs(projectedColumns[lhs].durableIndex - durableIndex)
            let rhsDistance = abs(projectedColumns[rhs].durableIndex - durableIndex)
            return lhsDistance == rhsDistance
                ? projectedColumns[lhs].durableIndex < projectedColumns[rhs].durableIndex
                : lhsDistance < rhsDistance
        } ?? 0
    }

    func projectedSelectedWindow(
        state: ViewportState,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriWindow? {
        let projectedColumns = projectedColumns(in: workspaceId)
        guard !projectedColumns.isEmpty else { return nil }

        if let selectedNodeId = state.selectedNodeId,
           let selectedWindow = findNode(by: selectedNodeId, in: workspaceId) as? NiriWindow,
           !isExcludedFromProjection(selectedWindow.token, in: workspaceId),
           let selectedColumn = column(of: selectedWindow),
           projectedColumns.contains(where: { $0.column === selectedColumn })
        {
            return selectedWindow
        }

        let projectedIndex = projectedActiveColumnIndex(
            state: state,
            columns: projectedColumns,
            in: workspaceId
        )
        let projectedColumn = projectedColumns[projectedIndex]
        return projectedActiveWindow(in: projectedColumn) ?? projectedColumn.windows.first
    }

    @discardableResult
    func reconcileProjectedSelection(
        state: inout ViewportState,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriWindow? {
        guard let selectedWindow = projectedSelectedWindow(state: state, in: workspaceId),
              let selectedColumn = column(of: selectedWindow),
              let durableIndex = columnIndex(of: selectedColumn, in: workspaceId)
        else {
            state.selectedNodeId = nil
            state.activeColumnIndex = 0
            return nil
        }

        state.selectedNodeId = selectedWindow.id
        state.activeColumnIndex = durableIndex
        return selectedWindow
    }

    func projectedPrimarySpan(
        for projectedColumn: NiriProjectedColumn,
        workingFrame: CGRect,
        gap: CGFloat,
        orientation: Monitor.Orientation
    ) -> CGFloat {
        let column = projectedColumn.column
        let windows = projectedColumn.windows
        let usesFittedSpan = orientation == .horizontal
            ? column.fittedWidth != nil
            : column.fittedHeight != nil
        if usesFittedSpan {
            return orientation == .horizontal ? column.cachedWidth : column.cachedHeight
        }
        if windows.count == column.windowNodes.count,
           !column.isTabbed || windows.count > 1
        {
            return orientation == .horizontal ? column.cachedWidth : column.cachedHeight
        }

        return rawProjectedPrimarySpan(
            for: projectedColumn,
            workingFrame: workingFrame,
            gap: gap,
            orientation: orientation
        )
    }

    func projectedPrimaryBounds(
        of windows: [NiriWindow],
        orientation: Monitor.Orientation,
        contentInset: CGFloat
    ) -> (min: CGFloat, max: CGFloat?) {
        var minimum: CGFloat = 1
        var maximum: CGFloat?
        for window in windows {
            let constraints = window.constraints.normalized()
            switch orientation {
            case .horizontal:
                minimum = max(minimum, constraints.minSize.width)
                if constraints.hasMaxWidth {
                    maximum = min(maximum ?? constraints.maxSize.width, constraints.maxSize.width)
                }
            case .vertical:
                minimum = max(minimum, constraints.minSize.height)
                if constraints.hasMaxHeight {
                    maximum = min(maximum ?? constraints.maxSize.height, constraints.maxSize.height)
                }
            }
        }
        return (minimum + contentInset, maximum.map { max($0, minimum) + contentInset })
    }

    func ensureProjectedSelectionVisible(
        node: NiriNode,
        context: NiriInteractionContext,
        state: inout ViewportState,
        animationConfig: SpringConfig?,
        fromContainerIndex: Int?,
        previousProjectedAnchor: NiriProjectedViewportAnchor? = nil
    ) {
        let projectedColumns = projectedColumns(in: context.workspaceId)
        guard !projectedColumns.isEmpty,
              let targetColumn = column(of: node),
              let targetProjectedIndex = projectedColumns.firstIndex(where: { $0.column === targetColumn })
        else {
            return
        }

        withProjectedPrimarySpans(
            projectedColumns,
            context: context
        ) {
            let containers = projectedColumns.map(\.column)

            var projectedState = state
            projectedState.activeColumnIndex = projectedActiveColumnIndex(
                state: state,
                columns: projectedColumns,
                in: context.workspaceId
            )
            projectedState.retargetColumn(
                to: targetProjectedIndex,
                columns: containers,
                gap: context.gaps,
                orientation: context.orientation,
                previousPosition: previousProjectedAnchor?.primaryPosition
            )

            let projectedFromIndex = previousProjectedAnchor?.projectedIndex
                ?? fromContainerIndex.flatMap { durableIndex in
                    projectedColumns.firstIndex(where: { $0.durableIndex == durableIndex })
                }
            let settings = effectiveSettings(in: context.workspaceId)
            projectedState.ensureContainerVisible(
                containerIndex: targetProjectedIndex,
                containers: containers,
                context: context,
                animate: true,
                centerMode: settings.centerFocusedColumn,
                alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn,
                animationConfig: animationConfig,
                fromContainerIndex: projectedFromIndex,
                scale: displayScale(in: context.workspaceId),
                viewFrame: monitorForWorkspace(context.workspaceId)?.frame
            )
            state = projectedState
            state.activeColumnIndex = projectedColumns[targetProjectedIndex].durableIndex
        }
    }

    @discardableResult
    func endProjectedGesture(
        state: inout ViewportState,
        context: NiriInteractionContext,
        currentOffset: Double,
        projectedOffset: Double,
        snapToColumn: Bool = true,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false,
        viewFrame: CGRect? = nil,
        scale: CGFloat = 2
    ) -> NiriWindow? {
        let projectedColumns = projectedColumns(in: context.workspaceId)
        guard !projectedColumns.isEmpty else { return nil }

        return withProjectedPrimarySpans(
            projectedColumns,
            context: context
        ) {
            var projectedState = state
            projectedState.activeColumnIndex = projectedActiveColumnIndex(
                state: state,
                columns: projectedColumns,
                in: context.workspaceId
            )
            let viewportSpan: CGFloat = switch context.orientation {
            case .horizontal: context.workingFrame.width
            case .vertical: context.workingFrame.height
            }
            let singleRect = singleWindowScrollRect(
                in: context.workspaceId, workingFrame: context.workingFrame,
                gaps: LayoutGaps(horizontal: context.gaps, vertical: context.gaps)
            )
            let singleOriginOffset: CGFloat = singleRect.map {
                context.orientation == .horizontal
                    ? context.workingFrame.minX - $0.minX
                    : context.workingFrame.minY - $0.minY
            } ?? 0
            projectedState.rebaseOffset(by: singleOriginOffset)
            projectedState.endGesture(
                currentOffset: currentOffset + Double(singleOriginOffset),
                projectedOffset: projectedOffset + Double(singleOriginOffset),
                columns: projectedColumns.map(\.column),
                geometry: NiriViewportGeometry(
                    gap: context.gaps,
                    viewportSpan: viewportSpan,
                    orientation: context.orientation,
                    workingArea: context.workingFrame,
                    viewFrame: viewFrame,
                    scale: scale,
                    edgeOverscroll: effectiveSettings(in: context.workspaceId).edgeOverscroll
                ),
                motion: context.motion,
                snapToColumn: snapToColumn,
                centerMode: centerMode,
                alwaysCenterSingleColumn: alwaysCenterSingleColumn
            )

            projectedState.rebaseOffset(by: -singleOriginOffset)
            projectedState.preservesGestureOffset = effectiveSettings(in: context.workspaceId)
                .edgeOverscroll != .disabled
            let projectedIndex = projectedState.activeColumnIndex
                .clamped(to: 0 ... projectedColumns.count - 1)
            let activeColumn = projectedColumns[projectedIndex]
            let selectedWindow = projectedActiveWindow(in: activeColumn) ?? activeColumn.windows.first
            state = projectedState
            state.activeColumnIndex = activeColumn.durableIndex
            state.selectedNodeId = selectedWindow?.id
            return selectedWindow
        }
    }

    func withProjectedPrimarySpans<Result>(
        _ projectedColumns: [NiriProjectedColumn],
        context: NiriInteractionContext,
        _ operation: () -> Result
    ) -> Result {
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation,
            motion: context.motion
        )
        let originalSpans = projectedColumns.map {
            context.orientation == .horizontal ? $0.column.cachedWidth : $0.column.cachedHeight
        }
        for projectedColumn in projectedColumns {
            let span = singleWindowScrollRect(
                in: context.workspaceId, workingFrame: context.workingFrame,
                gaps: LayoutGaps(horizontal: context.gaps, vertical: context.gaps)
            )
            .map { context.orientation == .horizontal ? $0.width : $0.height }
            ?? projectedPrimarySpan(
                for: projectedColumn,
                workingFrame: context.workingFrame,
                gap: context.gaps,
                orientation: context.orientation
            )
            switch context.orientation {
            case .horizontal:
                projectedColumn.column.cachedWidth = span
            case .vertical:
                projectedColumn.column.cachedHeight = span
            }
        }
        defer {
            for (projectedColumn, span) in zip(projectedColumns, originalSpans) {
                switch context.orientation {
                case .horizontal:
                    projectedColumn.column.cachedWidth = span
                case .vertical:
                    projectedColumn.column.cachedHeight = span
                }
            }
        }
        return operation()
    }

    func withProjectedViewport<Result>(
        state: inout ViewportState,
        context: NiriInteractionContext,
        _ operation: ([NiriContainer], inout ViewportState) -> Result
    ) -> Result? {
        let projectedColumns = projectedColumns(in: context.workspaceId)
        guard !projectedColumns.isEmpty else { return nil }

        var projectedState = state
        projectedState.activeColumnIndex = projectedActiveColumnIndex(
            state: state,
            columns: projectedColumns,
            in: context.workspaceId
        )
        let result = withProjectedPrimarySpans(
            projectedColumns,
            context: context
        ) {
            operation(projectedColumns.map(\.column), &projectedState)
        }
        let projectedIndex = projectedState.activeColumnIndex.clamped(to: 0 ... projectedColumns.count - 1)
        state = projectedState
        state.activeColumnIndex = projectedColumns[projectedIndex].durableIndex
        return result
    }
}
