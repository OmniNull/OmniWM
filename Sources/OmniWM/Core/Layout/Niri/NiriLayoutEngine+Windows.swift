// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    func updateWindowConstraints(
        for token: WindowToken,
        constraints: WindowSizeConstraints,
        packingHints: ObservedPackingHints = .none,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot
    ) {
        assertSanctionedMutation()
        guard let node = states[workspaceId]?.nodesByToken[token] else { return }
        let normalized = constraints.normalized()
        let column = node.parent as? NiriContainer
        if node.packingHints != packingHints {
            node.packingHints = packingHints
            column?.invalidateCachedPrimarySpans()
        }
        guard node.constraints != normalized else { return }
        node.constraints = normalized
        guard let column else { return }
        if column.cachedHeight > 0 {
            column.cachedHeight = column.clampedToHeightBounds(column.cachedHeight)
        }
        let contentInset = tabContentInset(for: column)
        if let target = column.targetWidth {
            let clampedTarget = column.clampedToWidthBounds(
                target,
                contentInset: contentInset
            )
            if clampedTarget != target {
                column.animateWidthTo(
                    newWidth: clampedTarget,
                    clock: animationClock,
                    config: motion.scaled(windowMovementAnimationConfig),
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: motion.animationsEnabled
                )
            }
        } else if column.cachedWidth > 0 {
            column.cachedWidth = column.clampedToWidthBounds(
                column.cachedWidth,
                contentInset: contentInset
            )
        }
    }

    func addWindow(
        token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID,
        afterSelection selectedNodeId: NodeId?,
        focusedToken: WindowToken? = nil,
        containerSizingState: NiriContainerSizingState? = nil
    ) -> NiriWindow {
        let state = ensureState(for: workspaceId)
        if let existing = state.nodesByToken[token] {
            return existing
        }
        let root = state.root

        if let existingColumn = claimEmptyColumnIfWorkspaceEmpty(in: root) {
            initializeNewContainerSizing(existingColumn, in: workspaceId, initialState: containerSizingState)
            let windowNode = NiriWindow(token: token)
            existingColumn.appendChild(windowNode)
            state.index(windowNode)
            return windowNode
        }

        let referenceColumn: NiriContainer? = if let focusedToken,
                                                 let focusedNode = state.nodesByToken[focusedToken],
                                                 let col = column(of: focusedNode)
        {
            col
        } else if let selId = selectedNodeId,
                  let selNode = root.findNode(by: selId),
                  let col = column(of: selNode)
        {
            col
        } else {
            root.columns.last
        }

        let newColumn = NiriContainer()
        initializeNewContainerSizing(newColumn, in: workspaceId, initialState: containerSizingState)
        if let refCol = referenceColumn {
            root.insertAfter(newColumn, reference: refCol)
        } else {
            root.appendChild(newColumn)
        }

        let windowNode = NiriWindow(token: token)
        newColumn.appendChild(windowNode)

        state.index(windowNode)

        return windowNode
    }

    func workspaceIds(containing token: WindowToken) -> [WorkspaceDescriptor.ID] {
        states.compactMap { $0.value.nodesByToken[token] != nil ? $0.key : nil }
    }

    func workspaceIds() -> [WorkspaceDescriptor.ID] {
        Array(states.keys)
    }

    func findNode(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> NiriWindow? {
        states[workspaceId]?.nodesByToken[token]
    }

    func removeWindow(token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let state = states[workspaceId],
              let node = state.nodesByToken[token],
              let column = node.parent as? NiriContainer else { return }
        let wasSingleWindow = singleWindowLayoutContext(in: workspaceId) != nil

        cancelInteractions(for: Set([node.id]), in: workspaceId)
        column.adjustActiveTileIdxForRemoval(of: node)
        node.remove()
        state.unindex(node)
        if excludedTokensByWorkspace[workspaceId]?.remove(token) != nil,
           excludedTokensByWorkspace[workspaceId]?.isEmpty == true
        {
            excludedTokensByWorkspace.removeValue(forKey: workspaceId)
        }

        if column.displayMode == .tabbed, !column.children.isEmpty {
            column.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: column)
        }

        if column.children.isEmpty {
            let root = column.parent as? NiriRoot
            column.remove()

            if let root {
                for col in root.columns {
                    col.cachedWidth = 0
                }
            }
        }

        clearManualSpanOverridesOnSingleWindowEntry(in: workspaceId, wasSingleWindow: wasSingleWindow)
    }

    func clearManualSpanOverridesOnSingleWindowEntry(
        in workspaceId: WorkspaceDescriptor.ID,
        wasSingleWindow: Bool
    ) {
        guard !wasSingleWindow,
              let survivor = singleWindowLayoutContext(in: workspaceId)?.container else { return }
        survivor.hasManualSingleWindowWidthOverride = false
        survivor.hasManualSingleWindowHeightOverride = false
    }

    @discardableResult
    func rekeyWindow(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard oldToken != newToken,
              let state = states[workspaceId],
              state.nodesByToken[newToken] == nil,
              let node = state.nodesByToken.removeValue(forKey: oldToken)
        else {
            return false
        }

        node.token = newToken
        state.index(node)

        if var move = interactiveMove,
           move.workspaceId == workspaceId,
           move.windowId == node.id
        {
            move.windowToken = newToken
            interactiveMove = move
        }

        node.invalidateChildrenCache()
        return true
    }

    @discardableResult
    func syncWindows(
        _ tokens: [WindowToken],
        in workspaceId: WorkspaceDescriptor.ID,
        selectedNodeId: NodeId?,
        focusedToken: WindowToken? = nil,
        containerSizingStates: [WindowToken: NiriContainerSizingState]? = nil,
        windowSizingStates: [WindowToken: PersistedNiriWindowState]? = nil
    ) -> Set<WindowToken> {
        assertSanctionedMutation()
        let state = ensureState(for: workspaceId)

        let currentIdSet = Set(tokens)

        var removedHandles = Set<WindowToken>()

        for window in state.root.allWindows where !currentIdSet.contains(window.token) {
            removedHandles.insert(window.token)
            removeWindow(token: window.token, in: workspaceId)
        }

        for token in tokens where state.nodesByToken[token] == nil {
            let window = addWindow(
                token: token,
                to: workspaceId,
                afterSelection: selectedNodeId,
                focusedToken: focusedToken,
                containerSizingState: containerSizingStates?[token]
            )
            if let windowSizingState = windowSizingStates?[token] {
                applyPersistedWindowState(windowSizingState, to: window)
            }
        }

        return removedHandles
    }

    func validateSelection(
        _ selectedNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        guard let selectedId = selectedNodeId else {
            return columns(in: workspaceId).first?.firstChild()?.id
        }

        guard let root = root(for: workspaceId),
              let existingNode = root.findNode(by: selectedId)
        else {
            return columns(in: workspaceId).first?.firstChild()?.id
        }

        return existingNode.id
    }

    func fallbackSelectionOnRemoval(
        removing removingNodeId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        guard let root = root(for: workspaceId),
              let removingNode = root.findNode(by: removingNodeId)
        else {
            return nil
        }

        if let nextSibling = removingNode.nextSibling() {
            return nextSibling.id
        }

        if let prevSibling = removingNode.prevSibling() {
            return prevSibling.id
        }

        let cols = columns(in: workspaceId)
        if let currentCol = column(of: removingNode),
           let currentIdx = cols.firstIndex(where: { $0 === currentCol })
        {
            if currentIdx > 0, let window = cols[currentIdx - 1].firstChild() {
                return window.id
            }
            if currentIdx < cols.count - 1, let window = cols[currentIdx + 1].firstChild() {
                return window.id
            }
        }

        for col in cols where col.id != column(of: removingNode)?.id {
            if let firstWindow = col.firstChild() {
                return firstWindow.id
            }
        }

        return nil
    }

    func updateFocusTimestamp(for nodeId: NodeId, in workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let node = findNode(by: nodeId, in: workspaceId) as? NiriWindow else { return }
        node.lastFocusedTime = Date()
    }

    func updateFocusTimestamp(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) {
        guard let node = states[workspaceId]?.nodesByToken[token] else { return }
        node.lastFocusedTime = Date()
    }

    func findMostRecentlyFocusedWindow(
        excluding excludingNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriWindow? {
        let allWindows: [NiriWindow] = if let wsId = workspaceId, let root = root(for: wsId) {
            root.allWindows
        } else {
            Array(states.values.flatMap(\.root.allWindows))
        }

        let candidates = allWindows.filter { window in
            guard window.id != excludingNodeId, window.lastFocusedTime != nil else { return false }
            if let workspaceId {
                return !isExcludedFromProjection(window.token, in: workspaceId)
            }
            return !excludedTokensByWorkspace.values.contains { $0.contains(window.token) }
        }

        return candidates.max { ($0.lastFocusedTime ?? .distantPast) < ($1.lastFocusedTime ?? .distantPast) }
    }
}
