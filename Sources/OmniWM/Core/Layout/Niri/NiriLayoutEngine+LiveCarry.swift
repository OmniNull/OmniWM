// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func liveColumnMoveCanCarry(
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to target: NiriInteractionContext
    ) -> Bool {
        guard let move = liveColumnMove,
              move.workspaceId == sourceWorkspaceId,
              target.workspaceId != sourceWorkspaceId,
              target.orientation == .horizontal
        else { return false }
        return findNode(by: move.windowId, in: sourceWorkspaceId) is NiriWindow
    }

    func liveColumnMoveCarry(
        cursor: CGPoint,
        windowWidth: CGFloat?,
        from source: NiriInteractionContext,
        sourceState: inout ViewportState,
        to target: NiriInteractionContext,
        targetState: inout ViewportState
    ) -> [WindowToken] {
        assertSanctionedMutation()
        guard liveColumnMoveCanCarry(from: source.workspaceId, to: target),
              var move = liveColumnMove,
              let window = findNode(by: move.windowId, in: source.workspaceId) as? NiriWindow
        else { return [] }
        if move.landing != nil {
            _ = placeLiveLanding(nil, move: &move, context: source, state: &sourceState)
        }
        guard let column = window.parent as? NiriContainer else {
            replaceLiveColumnMove(with: move)
            return []
        }
        var carry = move.carry ?? .init(originalWorkspaceId: move.workspaceId, originalOwnSizing: move.ownSizing)
        let parked = leaveLiveStrip(window, move: move, context: source, state: &sourceState)
        restoreWidenedLiveColumn(carry.widenedColumn)
        if move.carry == nil {
            carry.parkedHomeColumn = parked
        }
        if target.workspaceId != carry.originalWorkspaceId,
           !carry.visitedStrips.contains(where: { $0.workspaceId == target.workspaceId })
        {
            let columns = columns(in: target.workspaceId)
            carry.visitedStrips.append(.init(
                workspaceId: target.workspaceId,
                viewport: targetState,
                activeColumnId: columns.indices.contains(targetState.activeColumnIndex)
                    ? columns[targetState.activeColumnIndex].id
                    : nil
            ))
        }
        carry.widenedColumn = widenLoneLiveColumn(context: target, state: &targetState)
        let carried = move.isWholeColumn ? column : NiriContainer()
        let inset = move.isWholeColumn ? tabContentInset(for: column) : 0
        let sizing = windowWidth.map { liveCarriedSizing(windowWidth: $0 + inset, context: target) } ?? move.ownSizing

        move.carry = carry
        move.forgetStrip()
        move.workspaceId = target.workspaceId
        move.homeSlotIndex = 0
        move.lockedTarget = nil
        move.ownWindowSizing = .init(size: 1.0, height: .default)
        move.ownSizing = sizing
        enterLiveStrip(carried, window: window, cursor: cursor, move: &move, context: target, state: &targetState)
        move.phase = .settling
        replaceLiveColumnMove(with: move)
        targetState.selectedNodeId = window.id
        return carried.windowNodes.map(\.token)
    }

    func liveColumnMoveReturnHome(
        contexts: [WorkspaceDescriptor.ID: NiriInteractionContext],
        viewports: inout [WorkspaceDescriptor.ID: ViewportState]
    ) -> [WindowToken] {
        assertSanctionedMutation()
        guard var move = liveColumnMove,
              let carry = move.carry,
              let current = contexts[move.workspaceId],
              let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow,
              let column = window.parent as? NiriContainer
        else { return [] }
        var currentState = viewports[current.workspaceId] ?? ViewportState()
        if move.landing != nil {
            _ = placeLiveLanding(nil, move: &move, context: current, state: &currentState)
        }
        _ = leaveLiveStrip(window, move: move, context: current, state: &currentState)
        restoreWidenedLiveColumn(carry.widenedColumn)
        viewports[current.workspaceId] = currentState
        for visited in carry.visitedStrips {
            guard let context = contexts[visited.workspaceId], var state = viewports[visited.workspaceId] else {
                continue
            }
            restoreLiveVisitedStrip(visited, context: context, state: &state)
            viewports[visited.workspaceId] = state
        }

        let originalWorkspaceId = carry.originalWorkspaceId
        let workspaceState = ensureState(for: originalWorkspaceId)
        let home: NiriContainer
        if move.isWholeColumn {
            column.isLiveHomeSpot = false
            workspaceState.root.appendChild(column)
            home = column
        } else if let parked = carry.parkedHomeColumn {
            workspaceState.root.appendChild(parked)
            home = parked
        } else if let column = liveColumn(withId: move.originalSlot.columnId, in: originalWorkspaceId) {
            home = column
        } else {
            home = NiriContainer()
            workspaceState.root.appendChild(home)
            initializeNewContainerSizing(home, in: originalWorkspaceId, initialState: carry.originalOwnSizing)
        }
        if move.isWholeColumn {
            for node in home.windowNodes {
                workspaceState.index(node)
            }
        } else {
            home.appendChild(window)
            workspaceState.index(window)
        }

        move.carry = nil
        move.forgetStrip()
        move.workspaceId = originalWorkspaceId
        move.setHome(columnId: home.id, inStack: home.windowNodes.count > 1 && !move.isWholeColumn)
        move.homeSlotIndex = home.windowNodes.count - 1
        move.ownSizing = carry.originalOwnSizing
        move.lockedTarget = nil
        replaceLiveColumnMove(with: move)
        return move.isWholeColumn ? home.windowNodes.map(\.token) : [window.token]
    }

    func liveCarriedSizing(windowWidth: CGFloat, context: NiriInteractionContext) -> NiriContainerSizingState {
        let available = context.workingFrame.width - context.gaps
        let proportion = available > 0 ? (windowWidth + context.gaps) / available : 1
        return initialContainerSizingState(for: proportion.clamped(to: 0.05 ... 1.0))
    }

    func restoreWidenedLiveColumn(_ widened: LiveColumnMove.WidenedColumn?) {
        guard let widened, let column = liveColumn(withId: widened.columnId, in: widened.workspaceId) else { return }
        restoreLiveSizing(widened.sizing, to: column)
    }

    private func widenLoneLiveColumn(
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.WidenedColumn? {
        guard let single = singleWindowLayoutContext(in: context.workspaceId),
              let shown = single.window.frame
        else { return nil }
        let column = single.container
        let widened = LiveColumnMove.WidenedColumn(
            workspaceId: context.workspaceId,
            columnId: column.id,
            sizing: containerSizingState(for: column)
        )
        column.width = .fixed(shown.width)
        column.isFullWidth = false
        column.cachedWidth = 0
        column.widthAnimation = nil
        column.targetWidth = nil
        if let placed = liveColumnStrip(context: context, state: state).first(where: { $0.column === column }) {
            state.rebaseOffset(by: placed.minX - shown.minX)
        }
        return widened
    }

    private func liveStripAnchor(
        _ column: NiriContainer,
        leaving: Bool,
        in root: NiriRoot
    ) -> NiriContainer? {
        let columns = root.columns.filter { !$0.isLiveDropSpace }
        guard let index = columns.firstIndex(where: { $0 === column }) else { return nil }
        guard leaving else { return column }
        if index > 0 { return columns[index - 1] }
        return columns.indices.contains(index + 1) ? columns[index + 1] : nil
    }

    private func leaveLiveStrip(
        _ window: NiriWindow,
        move: LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriContainer? {
        guard let root = root(for: context.workspaceId),
              let column = window.parent as? NiriContainer
        else { return nil }
        let anchor = liveStripAnchor(
            column,
            leaving: move.isWholeColumn || column.windowNodes.count == 1,
            in: root
        )
        if let anchor {
            retargetActiveColumn(to: anchor, context: context, state: &state)
        }
        let before = primaryPositions(context: context, state: state)
        liveDropSpace(for: move)?.remove()
        var parked: NiriContainer?
        if move.isWholeColumn {
            column.detach()
            for node in column.windowNodes {
                states[context.workspaceId]?.unindex(node)
            }
        } else {
            window.detach()
            states[context.workspaceId]?.unindex(window)
        }
        if move.isWholeColumn {
            column.isLiveHomeSpot = false
        } else if column.windowNodes.isEmpty {
            column.detach()
            if move.carry == nil, column.id == move.originalSlot.columnId {
                parked = column
            }
        } else {
            if column.isTabbed, column.windowNodes.count == 1 {
                column.displayMode = .normal
            }
            column.setActiveTileIdx(min(column.activeTileIdx, column.windowNodes.count - 1))
            updateTabbedColumnVisibility(column: column)
            column.cachedWidth = 0
        }
        if let anchor {
            animateLiveColumnChange(from: before, anchoredOn: anchor, context: context, state: &state)
            state.selectedNodeId = anchor.windowNodes.first?.id
        } else {
            state.activeColumnIndex = 0
            state.selectedNodeId = nil
        }
        if let slot = move.narrowedSlot, slot.columnId == column.id {
            restoreLiveSlotWidth(slot, of: column)
        }
        return parked
    }

    private func enterLiveStrip(
        _ column: NiriContainer,
        window: NiriWindow,
        cursor: CGPoint,
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let workspaceState = ensureState(for: context.workspaceId)
        let root = workspaceState.root
        let strip = liveColumnStrip(context: context, state: state).filter { !$0.column.windowNodes.isEmpty }
        let under = strip.first { $0.contains(x: cursor.x) }?.column
            ?? strip.min { abs($0.midX - cursor.x) < abs($1.midX - cursor.x) }?.column
        let side = under.map {
            liveTargetSide($0, cursor: cursor, strip: strip, awayFromHome: false, context: context)
        } ?? .after
        if let under {
            retargetActiveColumn(to: under, context: context, state: &state)
        }
        let before = primaryPositions(context: context, state: state)
        move.originalViewPosition = liveViewPosition(positions: before, context: context, state: state)
            ?? state.viewOffset

        for empty in root.columns where strip.isEmpty && empty.windowNodes.isEmpty {
            empty.remove()
        }
        let isNew = column.windowNodes.isEmpty
        if let under, let index = root.children.firstIndex(where: { $0 === under }) {
            root.insertChild(column, at: side == .before ? index : index + 1)
        } else {
            root.appendChild(column)
        }
        applyContainerSizingState(move.ownSizing, to: column)
        column.fittedWidth = nil
        if isNew {
            column.appendChild(window)
            window.size = 1.0
            window.height = .default
        }
        for node in column.windowNodes {
            workspaceState.index(node)
        }
        updateTabbedColumnVisibility(column: column)
        move.setHome(columnId: column.id, inStack: false)
        closeLivePlace(column, toward: side, move: &move, context: context)
        guard let under else {
            state.activeColumnIndex = columnIndex(of: column, in: context.workspaceId) ?? 0
            return
        }
        openLiveDropSpace(
            leaving: column,
            beside: under,
            side: side,
            cursor: cursor,
            move: &move,
            context: context,
            state: &state
        )
    }

    private func restoreLiveVisitedStrip(
        _ visited: LiveColumnMove.VisitedStrip,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        if let activeId = visited.activeColumnId,
           let active = columns(in: context.workspaceId).first(where: { $0.id == activeId })
        {
            retargetActiveColumn(to: active, context: context, state: &state)
        }
        state.animateToOffset(
            visited.viewport.viewOffset,
            motion: context.motion,
            scale: displayScale(in: context.workspaceId)
        )
        state.selectedNodeId = visited.viewport.selectedNodeId
    }
}

extension LiveColumnMove {
    mutating func forgetStrip() {
        narrowedSlot = nil
        dropSpaceId = nil
        dwell = nil
        landing = nil
        mateHeight = nil
        stackMode = false
        pointerHold = nil
        edgeScrollSide = nil
        pulledStripEnd = nil
        originClosedToward = nil
    }
}
