// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct NiriTransferredColumn {
    let windows: [NiriWindow]
    let activeIndex: Int
    let sizing: NiriContainerSizingState?

    var activeWindow: NiriWindow {
        windows[activeIndex]
    }
}

extension NiriLayoutEngine {
    func detachColumnForTransfer(
        _ column: NiriContainer,
        from workspaceId: WorkspaceDescriptor.ID,
        sourceState: inout ViewportState
    ) -> NiriTransferredColumn? {
        assertSanctionedMutation()
        guard let workspace = states[workspaceId] else { return nil }
        let allColumns = columns(in: workspaceId)
        guard let index = allColumns.firstIndex(where: { $0 === column }) else { return nil }
        let windows = column.windowNodes
        guard !windows.isEmpty else { return nil }
        let sizing = containerSizingState(for: column)
        let activeIndex = min(column.activeTileIdx, windows.count - 1)
        let wasSingleWindow = singleWindowLayoutContext(in: workspaceId) != nil
        let fallback = index > 0 ? allColumns[index - 1].firstChild()?.id
            : (allColumns.count > 1 ? allColumns[1].firstChild()?.id : nil)
        var ids: Set<NodeId> = []
        for window in windows { ids.insert(window.id) }
        let retained = sourceState.selectedNodeId.flatMap { ids.contains($0) ? nil : $0 }
        cancelInteractions(for: ids, in: workspaceId)
        column.detach()
        for window in windows { workspace.unindex(window) }
        if index < sourceState.activeColumnIndex { sourceState.activeColumnIndex -= 1 }
        clearManualSpanOverridesOnSingleWindowEntry(in: workspaceId, wasSingleWindow: wasSingleWindow)
        sourceState.selectedNodeId = retained ?? fallback
        return NiriTransferredColumn(windows: windows, activeIndex: activeIndex, sizing: sizing)
    }

    func detachWindowForTransfer(
        _ window: NiriWindow,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        sourceState: inout ViewportState
    ) -> NiriContainerSizingState? {
        assertSanctionedMutation()
        guard let sourceWorkspaceState = states[sourceWorkspaceId],
              let sourceColumn = findColumn(containing: window, in: sourceWorkspaceId)
        else {
            return nil
        }

        let wasSingleWindow = singleWindowLayoutContext(in: sourceWorkspaceId) != nil
        let retainedSelection = sourceState.selectedNodeId.flatMap { selectedId in
            selectedId != window.id && findNode(by: selectedId, in: sourceWorkspaceId) != nil ? selectedId : nil
        }
        let fallbackSelection = retainedSelection
            ?? fallbackSelectionOnRemoval(removing: window.id, in: sourceWorkspaceId)

        cancelInteractions(for: Set([window.id]), in: sourceWorkspaceId)
        let sizing = containerSizingState(for: sourceColumn)

        window.detach()
        sourceWorkspaceState.unindex(window)

        let sourceColumnIndex = columnIndex(of: sourceColumn, in: sourceWorkspaceId)
        cleanupEmptyColumn(sourceColumn, in: sourceWorkspaceId, state: &sourceState)
        if let sourceColumnIndex,
           sourceColumn.parent == nil,
           sourceColumnIndex < sourceState.activeColumnIndex
        {
            sourceState.activeColumnIndex -= 1
        }
        clearManualSpanOverridesOnSingleWindowEntry(in: sourceWorkspaceId, wasSingleWindow: wasSingleWindow)

        sourceState.selectedNodeId = fallbackSelection
        return sizing
    }

    func attachTransferredColumn(
        _ transferred: NiriTransferredColumn,
        atDurableColumnIndex durableIndex: Int?,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) {
        assertSanctionedMutation()
        let workspaceState = ensureState(for: workspaceId)
        removeStaleNodes(for: transferred.windows, in: workspaceId)
        let root = workspaceState.root
        let column: NiriContainer
        if let claimed = claimEmptyColumnIfWorkspaceEmpty(in: root) {
            column = claimed
        } else {
            column = NiriContainer()
            let columns = root.columns
            if let durableIndex, columns.indices.contains(durableIndex) {
                root.insertBefore(column, reference: columns[durableIndex])
            } else {
                root.appendChild(column)
            }
        }
        initializeNewContainerSizing(column, in: workspaceId, initialState: transferred.sizing)
        for window in transferred.windows {
            column.appendChild(window)
            workspaceState.index(window)
        }
        if transferred.windows.count > 1 {
            column.displayMode = .tabbed
        }
        column.setActiveTileIdx(transferred.activeIndex)
        updateTabbedColumnVisibility(column: column)
        state.selectedNodeId = transferred.activeWindow.id
    }

    func attachTransferredWindow(
        _ window: NiriWindow,
        stackedWith target: NiriWindow,
        after: Bool,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) {
        assertSanctionedMutation()
        removeStaleNodes(for: [window], in: workspaceId)
        guard let column = findColumn(containing: target, in: workspaceId),
              let targetIndex = column.children.firstIndex(where: { $0 === target })
        else {
            attachTransferredColumn(
                NiriTransferredColumn(windows: [window], activeIndex: 0, sizing: nil),
                atDurableColumnIndex: nil,
                in: workspaceId,
                state: &state
            )
            return
        }
        column.insertChild(window, at: after ? targetIndex + 1 : targetIndex)
        window.size = 1.0
        window.height = .default
        ensureState(for: workspaceId).index(window)
        activateWindow(window.id, in: workspaceId)
        state.selectedNodeId = window.id
    }

    func swapWindowsAcrossWorkspaces(
        _ first: (window: NiriWindow, workspaceId: WorkspaceDescriptor.ID),
        _ second: (window: NiriWindow, workspaceId: WorkspaceDescriptor.ID),
        firstState: inout ViewportState,
        secondState: inout ViewportState
    ) {
        assertSanctionedMutation()
        guard let firstWorkspaceState = states[first.workspaceId],
              let secondWorkspaceState = states[second.workspaceId],
              let firstColumn = findColumn(containing: first.window, in: first.workspaceId),
              let secondColumn = findColumn(containing: second.window, in: second.workspaceId),
              let firstIndex = firstColumn.children.firstIndex(where: { $0 === first.window }),
              let secondIndex = secondColumn.children.firstIndex(where: { $0 === second.window })
        else {
            return
        }
        cancelInteractions(for: Set([first.window.id]), in: first.workspaceId)
        cancelInteractions(for: Set([second.window.id]), in: second.workspaceId)
        let firstSlot = (size: first.window.size, height: first.window.height)
        let secondSlot = (size: second.window.size, height: second.window.height)

        first.window.detach()
        firstWorkspaceState.unindex(first.window)
        second.window.detach()
        secondWorkspaceState.unindex(second.window)

        firstColumn.insertChild(second.window, at: firstIndex)
        secondColumn.insertChild(first.window, at: secondIndex)
        second.window.size = firstSlot.size
        second.window.height = firstSlot.height
        first.window.size = secondSlot.size
        first.window.height = secondSlot.height
        firstWorkspaceState.index(second.window)
        secondWorkspaceState.index(first.window)

        for column in [firstColumn, secondColumn] {
            updateTabbedColumnVisibility(column: column)
        }
        firstState.selectedNodeId = second.window.id
        secondState.selectedNodeId = first.window.id
    }

    func replaceWindowInSlot(
        _ partner: NiriWindow,
        with incoming: [NiriWindow],
        activeIndex: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) {
        assertSanctionedMutation()
        guard let workspaceState = states[workspaceId],
              let column = findColumn(containing: partner, in: workspaceId),
              let slotIndex = column.children.firstIndex(where: { $0 === partner }),
              incoming.indices.contains(activeIndex)
        else {
            return
        }
        cancelInteractions(for: Set([partner.id]), in: workspaceId)
        let slot = (size: partner.size, height: partner.height)
        partner.detach()
        workspaceState.unindex(partner)
        removeStaleNodes(for: incoming, in: workspaceId)

        for (offset, window) in incoming.enumerated() {
            column.insertChild(window, at: slotIndex + offset)
            workspaceState.index(window)
        }
        if incoming.count == 1 {
            incoming[0].size = slot.size
            incoming[0].height = slot.height
        } else {
            column.displayMode = .tabbed
            column.setActiveTileIdx(activeIndex)
        }
        updateTabbedColumnVisibility(column: column)
        state.selectedNodeId = incoming[activeIndex].id
    }

    private func removeStaleNodes(for windows: [NiriWindow], in workspaceId: WorkspaceDescriptor.ID) {
        guard let workspaceState = states[workspaceId] else { return }
        for window in windows {
            if let stale = workspaceState.nodesByToken[window.token], stale !== window {
                removeWindow(token: window.token, in: workspaceId)
            }
        }
    }
}
