// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    struct ColumnRenderPosition {
        let primaryPosition: CGFloat
        let renderOffset: CGPoint

        func displacement(
            to target: Self,
            secondary: CGFloat,
            orientation: Monitor.Orientation
        ) -> CGPoint {
            let sourceRender = switch orientation {
            case .horizontal: renderOffset.x
            case .vertical: renderOffset.y
            }
            let targetRender = switch orientation {
            case .horizontal: target.renderOffset.x
            case .vertical: target.renderOffset.y
            }
            let primary = primaryPosition + sourceRender - target.primaryPosition - targetRender
            return switch orientation {
            case .horizontal: CGPoint(x: primary, y: secondary)
            case .vertical: CGPoint(x: secondary, y: primary)
            }
        }
    }

    struct ColumnTransferResult {
        let sourceBecameEmpty: Bool
        let sourceColumnIndexBeforeCleanup: Int
        let targetColumnIndexAfterInsert: Int
    }

    enum TargetColumnInsertionPolicy {
        case append
        case visualBottom

        func insertionIndex(in targetColumn: NiriContainer) -> Int {
            switch self {
            case .append:
                targetColumn.children.count
            case .visualBottom:
                visualBottomInsertionIndex(in: targetColumn)
            }
        }

        private func visualBottomInsertionIndex(in _: NiriContainer) -> Int {
            // Current child ordering renders index 0 at the visual bottom of a column.
            0
        }
    }

    func resetMovedWindowColumnLocalSizing(_ window: NiriWindow) {
        window.height = .default
        window.windowWidth = .default
        window.resolvedHeight = nil
        window.resolvedWidth = nil
        window.heightFixedByConstraint = false
        window.widthFixedByConstraint = false
    }

    func primarySizeKeyPath(
        for orientation: Monitor.Orientation
    ) -> KeyPath<NiriContainer, CGFloat> {
        switch orientation {
        case .horizontal: \.cachedWidth
        case .vertical: \.cachedHeight
        }
    }

    func primaryDisplacement(
        _ primary: CGFloat,
        secondary: CGFloat = 0,
        orientation: Monitor.Orientation
    ) -> CGPoint {
        switch orientation {
        case .horizontal: CGPoint(x: primary, y: secondary)
        case .vertical: CGPoint(x: secondary, y: primary)
        }
    }

    func animateTransferredWindow(
        _ window: NiriWindow,
        from source: ColumnRenderPosition,
        to target: ColumnRenderPosition,
        secondary: CGFloat,
        context: NiriInteractionContext
    ) {
        let displacement = source.displacement(
            to: target,
            secondary: secondary,
            orientation: context.orientation
        )
        if displacement.x != 0 || displacement.y != 0 {
            window.animateMoveFrom(
                displacement: displacement,
                clock: animationClock,
                config: context.motion.scaled(windowMovementAnimationConfig),
                displayRefreshRate: displayRefreshRate(in: context.workspaceId),
                animated: context.motion.animationsEnabled
            )
        }
    }

    @discardableResult
    func moveWindowToColumn(
        _ node: NiriWindow,
        from sourceColumn: NiriContainer,
        to targetColumn: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        targetInsertionPolicy: TargetColumnInsertionPolicy = .append,
        activateInsertedWindowInTarget: Bool = false
    ) -> ColumnTransferResult {
        let sourceColumnIndexBeforeCleanup = columnIndex(of: sourceColumn, in: workspaceId) ?? 0
        let sourceWasTabbed = sourceColumn.displayMode == .tabbed
        let targetActiveTileIdxBeforeInsert = targetColumn.activeTileIdx
        sourceColumn.adjustActiveTileIdxForRemoval(of: node)

        node.detach()
        let insertedIndex = targetInsertionPolicy
            .insertionIndex(in: targetColumn)
            .clamped(to: 0 ... targetColumn.children.count)
        targetColumn.insertChild(node, at: insertedIndex)
        NiriLayoutTrace.record(
            .insertion,
            workspaceId: workspaceId,
            "moveToColumn index=\(insertedIndex) policy=\(String(describing: targetInsertionPolicy)) count=\(targetColumn.children.count)"
        )
        resetMovedWindowColumnLocalSizing(node)

        if sourceWasTabbed, !sourceColumn.children.isEmpty {
            sourceColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: sourceColumn)
        }

        if activateInsertedWindowInTarget {
            targetColumn.setActiveTileIdx(insertedIndex)
        } else if insertedIndex <= targetActiveTileIdxBeforeInsert {
            targetColumn.setActiveTileIdx(targetActiveTileIdxBeforeInsert + 1)
        }

        if targetColumn.displayMode == .tabbed {
            updateTabbedColumnVisibility(column: targetColumn)
        } else {
            node.isHiddenInTabbedMode = false
        }

        return ColumnTransferResult(
            sourceBecameEmpty: sourceColumn.children.isEmpty,
            sourceColumnIndexBeforeCleanup: sourceColumnIndexBeforeCleanup,
            targetColumnIndexAfterInsert: columnIndex(of: targetColumn, in: workspaceId) ??
                sourceColumnIndexBeforeCleanup
        )
    }

    func insertWindowInNewColumn(
        _ window: NiriWindow,
        insertIndex: Int,
        context: NiriInteractionContext,
        state: inout ViewportState,
        sizingPolicy: NewContainerSizingPolicy = .workspaceDefault
    ) -> Bool {
        assertSanctionedMutation()
        guard let root = root(for: context.workspaceId) else { return false }
        guard let sourceColumn = findColumn(containing: window, in: context.workspaceId) else { return false }

        let sourceWasTabbed = sourceColumn.displayMode == .tabbed
        sourceColumn.adjustActiveTileIdxForRemoval(of: window)

        let newColumn = NiriContainer()
        switch sizingPolicy {
        case .workspaceDefault:
            initializeNewContainerSizing(newColumn, in: context.workspaceId)
        case .inheritSource:
            copyContainerSizingState(from: sourceColumn, to: newColumn)
        }

        let cols = columns(in: context.workspaceId)
        let clampedIndex = insertIndex.clamped(to: 0 ... cols.count)
        if clampedIndex >= cols.count {
            root.appendChild(newColumn)
        } else {
            root.insertBefore(newColumn, reference: cols[clampedIndex])
        }

        if let newColIdx = columnIndex(of: newColumn, in: context.workspaceId) {
            animateColumnsForAddition(
                columnIndex: newColIdx,
                context: context,
                state: state
            )
        }

        window.detach()
        newColumn.appendChild(window)
        window.isHiddenInTabbedMode = false

        if sourceWasTabbed, !sourceColumn.children.isEmpty {
            sourceColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: sourceColumn)
        }

        cleanupEmptyColumn(sourceColumn, in: context.workspaceId, state: &state)

        ensureSelectionVisible(
            node: window,
            context: context,
            state: &state
        )

        return true
    }

    func cleanupEmptyColumn(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) {
        guard column.children.isEmpty else { return }

        // Window-close removals use removeWindows(...); this is structural cleanup for move/consume paths.
        column.remove()
    }

    private func clampedSpan(
        _ span: CGFloat,
        to bounds: (min: CGFloat, max: CGFloat?)
    ) -> CGFloat {
        let lowerBounded = max(span, bounds.min)
        return bounds.max.map { min(lowerBounded, $0) } ?? lowerBounded
    }

    @discardableResult
    func balanceSizes(
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        assertSanctionedMutation()
        let columns = projectedColumns(in: workspaceId)
        guard !columns.isEmpty else { return false }

        for projectedColumn in columns {
            beginManualPrimarySpanResize(projectedColumn.column, in: workspaceId, orientation: orientation)
        }

        let resolvedWidth = resolvedContainerResetPrimarySpan(in: workspaceId)
        switch orientation {
        case .horizontal:
            let targetPixels = (workingFrame.width - gaps) * resolvedWidth.proportion - gaps
            for projectedColumn in columns {
                let column = projectedColumn.column
                column.width = .proportion(resolvedWidth.proportion)
                column.isFullWidth = false
                column.savedWidth = nil
                column.presetWidthIdx = resolvedWidth.presetWidthIdx
                column.hasManualSingleWindowWidthOverride = false

                column.animateWidthTo(
                    newWidth: clampedSpan(
                        targetPixels,
                        to: projectedWidthBounds(for: column, workspaceId: workspaceId)
                    ),
                    clock: animationClock,
                    config: motion.scaled(windowMovementAnimationConfig),
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: motion.animationsEnabled
                )

                for window in projectedColumn.windows {
                    window.size = 1.0
                }
            }
        case .vertical:
            balanceColumnHeights(
                columns,
                proportion: resolvedWidth.proportion,
                targetPixels: (workingFrame.height - gaps) * resolvedWidth.proportion - gaps,
                in: workspaceId,
                motion: motion
            )
        }
        return true
    }

    private func balanceColumnHeights(
        _ columns: [NiriProjectedColumn],
        proportion: CGFloat,
        targetPixels: CGFloat,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot
    ) {
        for projectedColumn in columns {
            let column = projectedColumn.column
            column.height = .proportion(proportion)
            column.isFullHeight = false
            column.savedHeight = nil
            column.hasManualSingleWindowHeightOverride = false
            column.animateHeightTo(
                newHeight: clampedSpan(
                    targetPixels,
                    to: projectedHeightBounds(for: column, workspaceId: workspaceId)
                ),
                clock: animationClock,
                config: motion.scaled(windowMovementAnimationConfig),
                displayRefreshRate: displayRefreshRate(in: workspaceId),
                animated: motion.animationsEnabled
            )

            for window in projectedColumn.windows {
                window.windowWidth = .auto(weight: 1)
            }
        }
    }

    func ensureColumnVisible(
        _ column: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil,
        previousProjectedAnchor: NiriProjectedViewportAnchor? = nil
    ) {
        if let firstWindow = projectedWindows(in: column, workspaceId: context.workspaceId).first {
            ensureSelectionVisible(
                node: firstWindow,
                context: context,
                state: &state,
                animationConfig: animationConfig,
                fromContainerIndex: fromContainerIndex,
                previousProjectedAnchor: previousProjectedAnchor
            )
        }
    }
}
