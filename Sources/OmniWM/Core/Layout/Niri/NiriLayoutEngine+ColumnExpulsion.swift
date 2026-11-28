// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension NiriLayoutEngine {
    func expelWindowFromColumn(
        focusedColumn sourceColumn: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        let visibleWindows = projectedWindows(in: sourceColumn, workspaceId: context.workspaceId)
        guard visibleWindows.count > 1,
              let root = root(for: context.workspaceId),
              let sourceColumnIdx = columnIndex(of: sourceColumn, in: context.workspaceId),
              let window = visibleWindows.first
        else {
            return false
        }

        let snapshot = prepareColumnMutation(context: context)
        let now = animationClock?.now() ?? CACurrentMediaTime()
        let cols = columns(in: context.workspaceId)
        let sourceSample = sampleTransferredWindow(
            window, in: (sourceColumn, sourceColumnIdx), columns: cols, state: state,
            sampling: ColumnRenderSampling(geometry: snapshot.geometry, time: now, context: context)
        )
        let replacementSelectionId = visibleWindows.dropFirst().first?.id
        let selectedExpelledWindow = state.selectedNodeId == window.id

        let newColumn = NiriContainer()
        copyContainerSizingState(from: sourceColumn, to: newColumn)
        root.insertAfter(newColumn, reference: sourceColumn)

        _ = moveWindowToColumn(
            window,
            from: sourceColumn,
            to: newColumn,
            in: context.workspaceId
        )

        animateInsertedColumn(newColumn, snapshot: snapshot, context: context, state: state)

        let currentGeometry = completeColumnMutation(from: snapshot, context: context)
        animateExpelledWindow(
            window, into: newColumn,
            sample: WindowTransferAnimationSample(
                source: sourceSample, geometry: currentGeometry, time: now, context: context
            ), state: state
        )

        if selectedExpelledWindow {
            state.selectedNodeId = replacementSelectionId
        }

        return true
    }

    func expelWindow(
        _ window: NiriWindow,
        to direction: Direction,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        guard direction == .left || direction == .right else { return false }
        return expelWindow(window, into: direction == .right ? .after : .before, context: context, state: &state)
    }

    func expelWindow(
        _ window: NiriWindow,
        toProjectedPosition position: Int,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        expelWindow(window, into: .position(position), context: context, state: &state)
    }

    private enum ExpelSlot {
        case before
        case after
        case position(Int)
    }

    private func expelWindow(
        _ window: NiriWindow,
        into slot: ExpelSlot,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        guard let currentColumn = findColumn(containing: window, in: context.workspaceId),
              let root = root(for: context.workspaceId),
              let currentColIdx = columnIndex(of: currentColumn, in: context.workspaceId)
        else {
            return false
        }

        let snapshot = prepareColumnMutation(context: context)
        let previousProjectedAnchor = projectedViewportAnchor(
            state: state, geometry: snapshot.geometry, in: context.workspaceId
        )
        let now = animationClock?.now() ?? CACurrentMediaTime()
        let cols = columns(in: context.workspaceId)

        let sourceSample = sampleTransferredWindow(
            window, in: (currentColumn, currentColIdx), columns: cols, state: state,
            sampling: ColumnRenderSampling(geometry: snapshot.geometry, time: now, context: context)
        )

        let selectedColumn = state.selectedNodeId.flatMap { findNode(by: $0, in: context.workspaceId) }
            .flatMap { $0 === window ? nil : column(of: $0) }
        let wasTabbed = currentColumn.displayMode == .tabbed
        let newColumn = expelIntoNewColumn(
            window, from: currentColumn, root: root, slot: slot, workspaceId: context.workspaceId
        )
        if let selectedColumn, let index = columnIndex(of: selectedColumn, in: context.workspaceId) {
            state.activeColumnIndex = index
            state.activatePrevColumnOnRemoval = nil
            state.viewOffsetToRestore = nil
        }

        animateInsertedColumn(newColumn, snapshot: snapshot, context: context, state: state)

        let currentGeometry = completeColumnMutation(from: snapshot, context: context)
        animateExpelledWindow(
            window, into: newColumn,
            sample: WindowTransferAnimationSample(
                source: sourceSample, geometry: currentGeometry, time: now, context: context
            ), state: state
        )

        if wasTabbed, !currentColumn.children.isEmpty {
            currentColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: currentColumn)
        }

        cleanupEmptyColumn(currentColumn, in: context.workspaceId, state: &state)

        if selectedColumn == nil {
            ensureSelectionVisible(
                node: window,
                context: context,
                state: &state,
                previousProjectedAnchor: previousProjectedAnchor
            )
        }

        return true
    }

    private func expelIntoNewColumn(
        _ window: NiriWindow,
        from currentColumn: NiriContainer,
        root: NiriRoot,
        slot: ExpelSlot,
        workspaceId: WorkspaceDescriptor.ID
    ) -> NiriContainer {
        currentColumn.adjustActiveTileIdxForRemoval(of: window)

        let newColumn = NiriContainer()
        copyContainerSizingState(from: currentColumn, to: newColumn)

        window.detach()
        switch slot {
        case .before:
            root.insertBefore(newColumn, reference: currentColumn)
        case .after:
            root.insertAfter(newColumn, reference: currentColumn)
        case let .position(position):
            insertColumn(newColumn, at: .position(position), in: workspaceId)
        }

        newColumn.appendChild(window)
        resetMovedWindowColumnLocalSizing(window)
        window.isHiddenInTabbedMode = false

        return newColumn
    }
}
