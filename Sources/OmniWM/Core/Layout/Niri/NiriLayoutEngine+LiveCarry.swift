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
              let window = findNode(by: move.windowId, in: source.workspaceId) as? NiriWindow,
              let column = window.parent as? NiriContainer
        else { return [] }
        if move.landing != nil {
            _ = placeLiveLanding(nil, move: &move, context: source, state: &sourceState)
        }
        let narrowed = move.narrowedSlot.flatMap { slot in
            liveColumn(withId: slot.columnId, in: source.workspaceId).map { (slot: slot, column: $0) }
        }
        var carry = move.carry ?? .init(originalWorkspaceId: move.workspaceId, originalOwnSizing: move.ownSizing)
        let parked = leaveLiveStrip(window, move: move, context: source, state: &sourceState)
        if let narrowed {
            restoreLiveSlotWidth(narrowed.slot, of: narrowed.column)
        }
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
        let arrival = enterLiveStrip(
            carried,
            window: window,
            cursor: cursor,
            sizing: sizing,
            context: target,
            state: &targetState
        )

        move.carry = carry
        move.forgetStrip()
        move.workspaceId = target.workspaceId
        move.homeColumnId = arrival.column.id
        move.inStack = false
        move.homeSlotIndex = 0
        move.lockedTarget = arrival.lock
        move.ownWindowSizing = .init(size: 1.0, height: .default)
        move.ownSizing = sizing
        move.originalViewPosition = arrival.viewPosition
        move.phase = .settling
        liveColumnMove = move
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
        move.homeColumnId = home.id
        move.inStack = home.windowNodes.count > 1 && !move.isWholeColumn
        move.homeSlotIndex = home.windowNodes.count - 1
        move.ownSizing = carry.originalOwnSizing
        move.lockedTarget = nil
        liveColumnMove = move
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

    func moveLiveCarriedColumn(
        _ column: NiriContainer,
        beside target: NiriContainer,
        side: LiveColumnMove.Side,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        guard let root = root(for: context.workspaceId),
              column !== target,
              root.children.contains(where: { $0 === target }),
              root.children.contains(where: { $0 === column })
        else { return false }
        retargetActiveColumn(to: target, context: context, state: &state)
        let before = primaryPositions(context: context, state: state)
        column.detach()
        guard let targetIndex = root.children.firstIndex(where: { $0 === target }) else { return false }
        root.insertChild(column, at: side == .before ? targetIndex : targetIndex + 1)
        animateLiveColumnChange(from: before, anchoredOn: target, context: context, state: &state)
        return true
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
        return parked
    }

    private func enterLiveStrip(
        _ column: NiriContainer,
        window: NiriWindow,
        cursor: CGPoint,
        sizing: NiriContainerSizingState,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> (column: NiriContainer, lock: LiveColumnMove.TargetLock?, viewPosition: CGFloat) {
        let workspaceState = ensureState(for: context.workspaceId)
        let root = workspaceState.root
        let strip = liveColumnStrip(context: context, state: state).filter { !$0.column.windowNodes.isEmpty }
        let under = strip.first { $0.contains(x: cursor.x) }?.column
            ?? strip.min { abs($0.midX - cursor.x) < abs($1.midX - cursor.x) }?.column
        let side = under.map {
            liveTargetSide($0, cursor: cursor, strip: strip, home: $0, awayFromHome: false, context: context)
        } ?? .after
        if let under {
            retargetActiveColumn(to: under, context: context, state: &state)
        }
        let before = primaryPositions(context: context, state: state)
        let viewPosition = liveViewPosition(positions: before, context: context, state: state) ?? state.viewOffset

        if strip.isEmpty {
            for empty in root.columns where empty.windowNodes.isEmpty {
                empty.remove()
            }
        }
        let isNew = column.windowNodes.isEmpty
        column.isLiveHomeSpot = true
        if let under, let index = root.children.firstIndex(where: { $0 === under }) {
            root.insertChild(column, at: side == .before ? index : index + 1)
        } else {
            root.appendChild(column)
        }
        if isNew {
            initializeNewContainerSizing(column, in: context.workspaceId, initialState: sizing)
        }
        column.width = .fixed(liveDropSpaceWidth(context: context))
        column.isFullWidth = false
        column.fittedWidth = nil
        column.cachedWidth = 0
        if isNew {
            column.appendChild(window)
            window.size = 1.0
            window.height = .default
        }
        for node in column.windowNodes {
            workspaceState.index(node)
        }
        updateTabbedColumnVisibility(column: column)

        guard let under else {
            state.activeColumnIndex = columnIndex(of: column, in: context.workspaceId) ?? 0
            return (column, nil, viewPosition)
        }
        animateLiveColumnChange(from: before, anchoredOn: under, context: context, state: &state)
        scrollLiveLandingUnderPointer(column, target: under, cursor: cursor, context: context, state: &state)
        return (column, .init(columnId: under.id, side: side), viewPosition)
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
        slotClosing = .trailing
        slotLeads = nil
        passed = nil
        sideBySideIds = []
        dropSpaceId = nil
        hover = nil
        landing = nil
        landingIsHint = false
        centreWait = nil
        mateHeight = nil
        stackMode = false
        stackSuppressPoint = nil
        awaitsPointerMoveFrom = nil
        edgeScrollSide = nil
    }
}
