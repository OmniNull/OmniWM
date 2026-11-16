// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func liveColumnMoveCanCarry(
        from source: NiriInteractionContext,
        to target: NiriInteractionContext
    ) -> Bool {
        guard let move = liveColumnMove,
              move.workspaceId == source.workspaceId,
              target.workspaceId != source.workspaceId
        else { return false }
        return findNode(by: move.windowId, in: source.workspaceId) is NiriWindow
    }

    func liveColumnMoveCarry(
        cursor: CGPoint,
        windowPrimarySpan: CGFloat?,
        from source: NiriInteractionContext,
        to target: NiriInteractionContext,
        viewports: inout [WorkspaceDescriptor.ID: ViewportState]
    ) -> [WindowToken] {
        assertSanctionedMutation()
        var sourceState = viewports[source.workspaceId] ?? ViewportState()
        var targetState = viewports[target.workspaceId] ?? ViewportState()
        defer {
            viewports[source.workspaceId] = sourceState
            viewports[target.workspaceId] = targetState
        }
        guard liveColumnMoveCanCarry(from: source, to: target),
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
            carry.visitedStrips.append(liveVisitedStrip(in: target.workspaceId, viewport: targetState))
        }
        carry.widenedColumn = widenLoneLiveColumn(context: target, state: &targetState)
        let carried = liveCarriedColumn(for: window, from: column, wholeColumn: move.isWholeColumn)
        let inset = move.isWholeColumn && target.orientation == .horizontal ? tabContentInset(for: column) : 0
        let sizing = windowPrimarySpan.map { liveCarriedSizing(windowPrimarySpan: $0 + inset, context: target) }
            ?? move.ownSizing

        move.carry = carry
        move.forgetStrip()
        if source.orientation != target.orientation {
            move.heading = nil
            move.headingFromX = target.primaryCoordinate(of: cursor)
        }
        move.workspaceId = target.workspaceId
        move.homeSlotIndex = 0
        move.lockedTarget = nil
        move.ownWindowSizing = .init(height: .default, windowWidth: .default)
        move.ownSizing = sizing
        enterLiveStrip(carried, cursor: cursor, move: &move, context: target, state: &targetState)
        move.phase = .settling
        replaceLiveColumnMove(with: move)
        targetState.selectedNodeId = window.id
        return carried.windowNodes.map(\.token)
    }

    private func liveVisitedStrip(
        in workspaceId: WorkspaceDescriptor.ID,
        viewport: ViewportState
    ) -> LiveColumnMove.VisitedStrip {
        let columns = columns(in: workspaceId)
        return .init(
            workspaceId: workspaceId,
            viewport: viewport,
            activeColumnId: columns.indices.contains(viewport.activeColumnIndex)
                ? columns[viewport.activeColumnIndex].id
                : nil
        )
    }

    private func liveCarriedColumn(
        for window: NiriWindow,
        from column: NiriContainer,
        wholeColumn: Bool
    ) -> NiriContainer {
        guard !wholeColumn else { return column }
        let carried = NiriContainer()
        resetMovedWindowColumnLocalSizing(window)
        carried.appendChild(window)
        return carried
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
              window.parent is NiriContainer
        else { return [] }
        var currentState = viewports[current.workspaceId] ?? ViewportState()
        if move.landing != nil {
            _ = placeLiveLanding(nil, move: &move, context: current, state: &currentState)
        }
        guard let column = window.parent as? NiriContainer else {
            viewports[current.workspaceId] = currentState
            replaceLiveColumnMove(with: move)
            return []
        }
        _ = leaveLiveStrip(window, move: move, context: current, state: &currentState)
        restoreWidenedLiveColumn(carry.widenedColumn)
        viewports[current.workspaceId] = currentState
        restoreLiveVisitedStrips(carry.visitedStrips, contexts: contexts, viewports: &viewports)
        let home = rebuildLiveHome(
            wholeColumn: move.isWholeColumn,
            originalColumnId: move.originalSlot.columnId,
            carry: carry,
            from: column,
            window: window
        )

        move.carry = nil
        move.forgetStrip()
        move.workspaceId = carry.originalWorkspaceId
        move.setHome(columnId: home.id, inStack: home.windowNodes.count > 1 && !move.isWholeColumn)
        move.homeSlotIndex = home.windowNodes.count - 1
        move.ownSizing = carry.originalOwnSizing
        move.lockedTarget = nil
        replaceLiveColumnMove(with: move)
        return move.isWholeColumn ? home.windowNodes.map(\.token) : [window.token]
    }

    private func restoreLiveVisitedStrips(
        _ visitedStrips: [LiveColumnMove.VisitedStrip],
        contexts: [WorkspaceDescriptor.ID: NiriInteractionContext],
        viewports: inout [WorkspaceDescriptor.ID: ViewportState]
    ) {
        for visited in visitedStrips {
            guard let context = contexts[visited.workspaceId], var state = viewports[visited.workspaceId] else {
                continue
            }
            restoreLiveVisitedStrip(visited, context: context, state: &state)
            viewports[visited.workspaceId] = state
        }
    }

    private func rebuildLiveHome(
        wholeColumn: Bool,
        originalColumnId: NodeId,
        carry: LiveColumnMove.Carry,
        from column: NiriContainer,
        window: NiriWindow
    ) -> NiriContainer {
        let originalWorkspaceId = carry.originalWorkspaceId
        let workspaceState = ensureState(for: originalWorkspaceId)
        let home: NiriContainer
        if wholeColumn {
            column.isLiveHomeSpot = false
            workspaceState.root.appendChild(column)
            home = column
        } else if let parked = carry.parkedHomeColumn {
            workspaceState.root.appendChild(parked)
            home = parked
        } else if let column = liveColumn(withId: originalColumnId, in: originalWorkspaceId) {
            home = column
        } else {
            home = NiriContainer()
            workspaceState.root.appendChild(home)
            initializeNewContainerSizing(home, in: originalWorkspaceId, initialState: carry.originalOwnSizing)
        }
        if wholeColumn {
            for node in home.windowNodes {
                workspaceState.index(node)
            }
        } else {
            home.appendChild(window)
            workspaceState.index(window)
        }
        return home
    }

    func liveCarriedSizing(windowPrimarySpan: CGFloat, context: NiriInteractionContext) -> NiriContainerSizingState {
        let available = context.primarySpan - context.gaps
        let proportion = available > 0 ? (windowPrimarySpan + context.gaps) / available : 1
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
        if context.orientation == .horizontal {
            column.width = .fixed(shown.width)
            column.isFullWidth = false
            column.cachedWidth = 0
            column.widthAnimation = nil
            column.targetWidth = nil
        } else {
            column.height = .fixed(shown.height)
            column.isFullHeight = false
            column.cachedHeight = 0
            column.heightAnimation = nil
            column.targetHeight = nil
        }
        let shownStart = context.primaryStart(of: shown)
        if let placed = liveColumnStrip(context: context, state: state).first(where: { $0.column === column }) {
            state.rebaseOffset(by: placed.minX - shownStart)
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
            column.setCachedPrimarySpan(0, orientation: context.orientation)
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
        cursor: CGPoint,
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let workspaceState = ensureState(for: context.workspaceId)
        let strip = liveColumnStrip(context: context, state: state).filter { !$0.column.windowNodes.isEmpty }
        let primary = context.primaryCoordinate(of: cursor)
        let under = strip.first { $0.contains(x: primary) }?.column
            ?? strip.min { abs($0.midX - primary) < abs($1.midX - primary) }?.column
        let side = under.map {
            liveTargetSide($0, cursor: cursor, strip: strip, awayFromHome: false, context: context)
        } ?? .after
        if let under {
            retargetActiveColumn(to: under, context: context, state: &state)
        }
        let before = primaryPositions(context: context, state: state)
        move.originalViewPosition = liveViewPosition(positions: before, context: context, state: state)
            ?? state.viewOffset

        placeLiveColumn(column, beside: under, side: side, sizing: move.ownSizing, in: workspaceState)
        if context.orientation == .horizontal { column.fittedWidth = nil }
        else { column.fittedHeight = nil }
        move.setHome(columnId: column.id, inStack: false)
        closeLivePlace(column, toward: side, move: &move, context: context)
        guard let under else {
            state.activeColumnIndex = columnIndex(of: column, in: context.workspaceId) ?? 0
            return
        }
        let entered = liveColumnStrip(context: context, state: state)
        let pin = liveDropSpacePin(
            leaving: column,
            beside: under,
            heading: move.heading,
            strip: entered,
            at: primary
        )
        _ = applyLiveReorder(
            .init(
                dragged: column,
                target: under,
                side: side,
                pinned: pin.pinned,
                kind: .openDropSpace(existing: nil, beside: column)
            ),
            cursor: cursor,
            move: &move,
            context: context,
            state: &state
        )
        move.lockedTarget = liveTargetLock(under: pin.under, cursor: cursor, strip: entered, context: context)
    }

    private func placeLiveColumn(
        _ column: NiriContainer,
        beside under: NiriContainer?,
        side: LiveColumnMove.Side,
        sizing: NiriContainerSizingState,
        in workspaceState: NiriWorkspaceState
    ) {
        let root = workspaceState.root
        if under == nil {
            for empty in root.columns where empty.windowNodes.isEmpty {
                empty.remove()
            }
        }
        if let under, let index = root.children.firstIndex(where: { $0 === under }) {
            root.insertChild(column, at: side == .before ? index : index + 1)
        } else {
            root.appendChild(column)
        }
        applyContainerSizingState(sizing, to: column)
        for node in column.windowNodes {
            workspaceState.index(node)
        }
        updateTabbedColumnVisibility(column: column)
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
        pointerHold = nil
        edgeScrollSide = nil
        pulledStripEnd = nil
        originClosedToward = nil
    }
}
