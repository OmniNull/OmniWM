// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

enum NiriColumnPlacement: Equatable, Sendable {
    case append
    case position(Int)
}

extension NiriLayoutEngine {
    func insertColumn(
        _ column: NiriContainer,
        at placement: NiriColumnPlacement,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let root = root(for: workspaceId) else { return }
        if case let .position(position) = placement {
            let projected = projectedColumns(in: workspaceId)
            if projected.indices.contains(position) {
                root.insertChild(column, at: projected[position].durableIndex)
                return
            }
        }
        root.appendChild(column)
    }

    struct WorkspaceMoveResult {
        let newFocusNodeId: NodeId?

        let movedToken: WindowToken?

        let targetWorkspaceId: WorkspaceDescriptor.ID
    }

    func moveWindowToWorkspace(
        _ window: NiriWindow,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        placement: NiriColumnPlacement? = nil,
        sourceState: inout ViewportState,
        targetState: inout ViewportState
    ) -> WorkspaceMoveResult? {
        assertSanctionedMutation()
        guard sourceWorkspaceId != targetWorkspaceId,
              states[sourceWorkspaceId] != nil,
              findColumn(containing: window, in: sourceWorkspaceId) != nil
        else {
            return nil
        }

        let targetWorkspaceState = ensureState(for: targetWorkspaceId)
        if targetWorkspaceState.nodesByToken[window.token] != nil {
            removeWindow(token: window.token, in: targetWorkspaceId)
        }
        precondition(targetWorkspaceState.nodesByToken[window.token] == nil)

        guard let sizing = detachWindowForTransfer(window, from: sourceWorkspaceId, sourceState: &sourceState) else {
            return nil
        }

        let targetColumn: NiriContainer
        if let existingColumn = claimEmptyColumnIfWorkspaceEmpty(in: targetWorkspaceState.root) {
            targetColumn = existingColumn
        } else {
            let newColumn = NiriContainer()
            insertColumn(newColumn, at: placement ?? .append, in: targetWorkspaceId)
            targetColumn = newColumn
        }
        initializeNewContainerSizing(targetColumn, in: targetWorkspaceId, initialState: sizing)
        targetColumn.appendChild(window)
        targetWorkspaceState.index(window)

        targetState.selectedNodeId = window.id

        return WorkspaceMoveResult(
            newFocusNodeId: sourceState.selectedNodeId,
            movedToken: window.token,
            targetWorkspaceId: targetWorkspaceId
        )
    }

    func moveColumnToWorkspace(
        _ column: NiriContainer,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to destination: NiriWorkspaceDestination,
        sourceState: inout ViewportState,
        targetState: inout ViewportState
    ) -> WorkspaceMoveResult? {
        let targetWorkspaceId = destination.workspaceId
        assertSanctionedMutation()
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard let sourceWorkspaceState = states[sourceWorkspaceId],
              columnIndex(of: column, in: sourceWorkspaceId) != nil
        else {
            return nil
        }

        let wasSingleWindow = singleWindowLayoutContext(in: sourceWorkspaceId) != nil
        let targetWorkspaceState = ensureState(for: targetWorkspaceId)
        let targetRoot = targetWorkspaceState.root
        let movedWindows = column.windowNodes

        for window in movedWindows where targetWorkspaceState.nodesByToken[window.token] != nil {
            removeWindow(token: window.token, in: targetWorkspaceId)
        }
        precondition(movedWindows.allSatisfy { targetWorkspaceState.nodesByToken[$0.token] == nil })

        removeEmptyColumnsIfWorkspaceEmpty(in: targetRoot)

        let allCols = columns(in: sourceWorkspaceId)
        let sourceColumnIndex = columnIndex(of: column, in: sourceWorkspaceId)
        var fallbackSelection: NodeId?
        if let colIdx = sourceColumnIndex {
            if colIdx > 0 {
                fallbackSelection = allCols[colIdx - 1].firstChild()?.id
            } else if allCols.count > 1 {
                fallbackSelection = allCols[1].firstChild()?.id
            }
        }

        cancelInteractions(for: Set(movedWindows.map(\.id)), in: sourceWorkspaceId)

        column.detach()
        if let sourceColumnIndex, sourceColumnIndex < sourceState.activeColumnIndex {
            sourceState.activeColumnIndex -= 1
        }
        targetRoot.appendChild(column)
        column.invalidateCachedPrimarySpan(orientation: destination.orientation)

        for window in movedWindows {
            sourceWorkspaceState.unindex(window)
            targetWorkspaceState.index(window)
        }
        clearManualSpanOverridesOnSingleWindowEntry(in: sourceWorkspaceId, wasSingleWindow: wasSingleWindow)

        sourceState.selectedNodeId = fallbackSelection

        targetState.selectedNodeId = column.firstChild()?.id

        let firstWindowToken = movedWindows.first?.token

        return WorkspaceMoveResult(
            newFocusNodeId: fallbackSelection,
            movedToken: firstWindowToken,
            targetWorkspaceId: targetWorkspaceId
        )
    }

    func removeWorkspaceState(_ workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        cancelInteractions(in: workspaceId)
        for niriMonitor in monitors.values {
            niriMonitor.workspaceRoots.removeValue(forKey: workspaceId)
        }
        states.removeValue(forKey: workspaceId)
        excludedTokensByWorkspace.removeValue(forKey: workspaceId)
    }
}
