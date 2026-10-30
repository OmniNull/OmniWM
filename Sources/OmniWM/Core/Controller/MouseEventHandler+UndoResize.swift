// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct NativeResizeUndo {
    struct ColumnSizing: Equatable {
        let sizing: NiriContainerSizingState
        let fittedWidth: CGFloat?
        let fittedHeight: CGFloat?
        let windows: [WindowToken: WindowSpans]

        init(_ column: NiriContainer, engine: NiriLayoutEngine) {
            sizing = engine.containerSizingState(for: column)
            fittedWidth = column.fittedWidth
            fittedHeight = column.fittedHeight
            windows = Dictionary(
                uniqueKeysWithValues: column.windowNodes.map { ($0.token, WindowSpans($0, in: column)) }
            )
        }
    }

    struct WindowSpans: Equatable {
        let height: WeightedSize
        let windowWidth: WeightedSize
        let savedHeight: WeightedSize?
        let sizingMode: SizingMode
        let restsAtTop: Bool

        init(_ window: NiriWindow, in column: NiriContainer) {
            height = window.height
            windowWidth = window.windowWidth
            savedHeight = window.savedHeight
            sizingMode = window.sizingMode
            restsAtTop = window.restsAtTop(of: column)
        }

        func restore(_ window: NiriWindow, in column: NiriContainer) {
            window.height = height
            window.windowWidth = windowWidth
            window.savedHeight = savedHeight
            window.sizingMode = sizingMode
            window.rest(atTop: restsAtTop, in: column)
        }
    }

    struct Start {
        let column: NiriContainer
        let sizing: ColumnSizing
        let manualColumnCounts: (width: Int?, height: Int?)
    }

    let workspaceId: WorkspaceDescriptor.ID
    let columnId: NodeId
    let edges: ResizeEdge
    let before: ColumnSizing
    let after: ColumnSizing
    let manualColumnCounts: (width: Int?, height: Int?)
}

extension MouseEventHandler {
    func nativeResizeUndoStart(
        for window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NativeResizeUndo.Start? {
        guard let engine = controller?.niriEngine,
              let column = engine.findColumn(containing: window, in: workspaceId)
        else { return nil }
        let workspace = engine.states[workspaceId]
        return NativeResizeUndo.Start(
            column: column,
            sizing: NativeResizeUndo.ColumnSizing(column, engine: engine),
            manualColumnCounts: (workspace?.manualWidthColumnCount, workspace?.manualHeightColumnCount)
        )
    }

    func rememberNativeResize(
        of token: WindowToken,
        edges: ResizeEdge,
        in workspaceId: WorkspaceDescriptor.ID,
        from start: NativeResizeUndo.Start
    ) {
        guard let controller, let engine = controller.niriEngine else { return }
        state.nativeResizeUndos = state.nativeResizeUndos.filter {
            controller.workspaceManager.entry(for: $0.key) != nil
        }
        let after = NativeResizeUndo.ColumnSizing(start.column, engine: engine)
        guard after != start.sizing else { return }
        state.nativeResizeUndos[token] = NativeResizeUndo(
            workspaceId: workspaceId,
            columnId: start.column.id,
            edges: edges,
            before: start.sizing,
            after: after,
            manualColumnCounts: start.manualColumnCounts
        )
    }

    @discardableResult
    func undoNativeResize(on target: NiriLayoutHandler.WindowTarget) -> Bool {
        guard let controller else { return false }
        return controller.niriLayoutHandler.performWindowSizing(on: target) { engine, window, context, viewport in
            guard let undo = state.nativeResizeUndos.removeValue(forKey: window.token),
                  undo.workspaceId == context.workspaceId,
                  let column = engine.findColumn(containing: window, in: context.workspaceId),
                  column.id == undo.columnId,
                  NativeResizeUndo.ColumnSizing(column, engine: engine) == undo.after
            else { return nil }
            restoreNativeResize(undo, column: column, engine: engine, context: context, state: &viewport)
            return .containerPrimarySpanChanged
        }
    }

    private func restoreNativeResize(
        _ undo: NativeResizeUndo,
        column: NiriContainer,
        engine: NiriLayoutEngine,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let before = undo.before.sizing
        let horizontal = context.orientation == .horizontal
        let primaryEdges = undo.edges.intersection(horizontal ? [.left, .right] : [.top, .bottom])
        if horizontal, !primaryEdges.isEmpty, before.width != undo.after.sizing.width
            || before.isFullWidth != undo.after.sizing.isFullWidth
        {
            let centre = engine.columnScreenSpan(column, context: context, state: state)
                .map { ($0.lowerBound + $0.upperBound) / 2 }
            let width = column.resolvedWidthPixels(
                before.isFullWidth ? .proportion(1) : before.width,
                availableSpan: context.workingFrame.width,
                gaps: context.gaps,
                contentInset: engine.tabContentInset(for: column)
            )
            let keepsRight = primaryEdges == .left
            engine.stretchColumn(
                column,
                to: ColumnStretch(width: width, keptSideShift: 0),
                rightSide: !keepsRight,
                context: context,
                state: &state
            )
            if primaryEdges.contains([.left, .right]), let centre {
                engine.centreColumn(column, on: centre, animated: true, context: context, state: &state)
            }
        } else {
            column.cachedHeight = 0
        }
        column.width = before.width
        column.presetWidthIdx = before.presetWidthIndex
        column.isFullWidth = before.isFullWidth
        column.savedWidth = before.savedWidth
        column.hasManualSingleWindowWidthOverride = before.hasManualSingleWindowWidthOverride
        column.height = before.height
        column.isFullHeight = before.isFullHeight
        column.savedHeight = before.savedHeight
        column.hasManualSingleWindowHeightOverride = before.hasManualSingleWindowHeightOverride
        column.fittedWidth = undo.before.fittedWidth
        column.fittedHeight = undo.before.fittedHeight
        for window in column.windowNodes {
            undo.before.windows[window.token]?.restore(window, in: column)
        }
        let workspace = engine.ensureState(for: context.workspaceId)
        workspace.manualWidthColumnCount = undo.manualColumnCounts.width
        workspace.manualHeightColumnCount = undo.manualColumnCounts.height
    }
}
