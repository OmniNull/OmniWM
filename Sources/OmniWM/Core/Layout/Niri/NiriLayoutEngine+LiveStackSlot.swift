// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func liveInStackDecision(
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        move: inout LiveColumnMove,
        context: NiriInteractionContext
    ) -> LiveColumnMove.Action {
        guard let home = liveDraggedColumn(for: move),
              let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow,
              let placed = strip.first(where: { $0.column === home })
        else { return .nothing }

        if let leaving = liveStackLeaveSide(placed, at: cursor.x, move: move) {
            return .leaveStack(towardTrailingSide: leaving == .after)
        }
        guard !holdsLiveStackSuppression(&move, at: cursor, strip: strip) else { return .nothing }
        guard let index = liveSlotTarget(at: cursor, in: home, window: window, context: context) else {
            return .nothing
        }
        return .moveInStack(window, home: home, index: index)
    }

    private func liveStackLeaveSide(
        _ placed: LiveColumnMove.StripColumn,
        at x: CGFloat,
        move: LiveColumnMove
    ) -> LiveColumnMove.Side? {
        let inset = !move.pullsTab
            ? placed.width * max(0, 0.5 - MoveConfiguration.liveStackLeaveOutsideShare)
            : 0
        if x >= placed.maxX - inset { return .after }
        if x < placed.minX + inset { return .before }
        return nil
    }

    func liveInStackEnd(
        releasedAt release: CGRect?,
        move: LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        endLiveColumnMove()
        guard let home = liveDraggedColumn(for: move),
              let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow,
              window.parent === home
        else { return true }
        settleLiveWindow(window, in: home, releasedAt: release, context: context, state: &state)
        return true
    }

    func restoreLiveOriginalSlot(_ move: inout LiveColumnMove) {
        let original = move.originalSlot
        guard let column = liveColumn(withId: original.columnId, in: move.workspaceId),
              let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow
        else { return }
        let current = liveDraggedColumn(for: move)
        if window.parent !== column || column.windowNodes.firstIndex(where: { $0 === window }) != original.index {
            column.insertChild(window, at: original.index)
            column.cachedWidth = 0
        }
        original.windowSizing.apply(to: window)
        if column.displayMode != original.displayMode {
            column.displayMode = original.displayMode
            column.cachedWidth = 0
        }
        column.setActiveTileIdx(original.activeTileIdx)
        updateTabbedColumnVisibility(column: column)
        if let current, current !== column, current.windowNodes.isEmpty {
            current.remove()
        }
        move.setHome(
            columnId: column.id,
            inStack: projectedWindows(in: column, workspaceId: move.workspaceId).count > 1 && !move.isWholeColumn
        )
        move.homeSlotIndex = original.index
        move.ownWindowSizing = original.windowSizing
    }

    func liveColumnMoveDetachTab(
        towardTrailingSide: Bool,
        cursor: CGPoint,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard var move = liveColumnMove, move.pullsTab, move.home == .stackSlot, move.workspaceId == context.workspaceId
        else { return false }
        defer { liveColumnMove = move }
        return leaveLiveStack(
            towardTrailingSide: towardTrailingSide,
            cursor: cursor,
            move: &move,
            context: context,
            state: &state
        )
    }

    func liveFloatingFrame(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> CGRect? {
        guard let move = liveColumnMove, move.windowToken == token, move.workspaceId == workspaceId else {
            return nil
        }
        return move.floatingFrame
    }

    private func liveSlotTarget(
        at cursor: CGPoint,
        in home: NiriContainer,
        window: NiriWindow,
        context: NiriInteractionContext
    ) -> Int? {
        guard !home.isTabbed else { return nil }
        let spans = liveWindowSpans(in: home, context: context)
        guard !spans.contains(where: { $0.window === window && $0.contains(y: cursor.y) }),
              let mate = spans.first(where: { $0.window !== window && $0.contains(y: cursor.y) })
        else { return nil }
        return home.windowNodes.firstIndex { $0 === mate.window }
    }

    func moveLiveSlot(
        _ window: NiriWindow,
        in home: NiriContainer,
        to index: Int,
        context: NiriInteractionContext
    ) {
        slideLiveWindows(in: [home], skipping: window, context: context) {
            home.insertChild(window, at: index)
            activateWindow(window.id, in: context.workspaceId)
        }
    }

    func leaveLiveStack(
        towardTrailingSide: Bool,
        cursor: CGPoint,
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        guard let home = liveDraggedColumn(for: move),
              let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow,
              let root = root(for: move.workspaceId),
              let homeIndex = root.children.firstIndex(where: { $0 === home })
        else { return false }
        let screenBefore = liveScreenPositions(context: context, state: state)
        let positionsBefore = primaryPositions(context: context, state: state)
        let column = slideLiveWindows(in: [home], skipping: window, context: context) {
            detachLiveWindow(
                window,
                from: home,
                at: towardTrailingSide ? homeIndex + 1 : homeIndex,
                sizing: move.ownSizing,
                context: context
            )
        }
        let side: LiveColumnMove.Side = towardTrailingSide ? .after : .before
        move.setHome(columnId: column.id, inStack: false)
        move.homeSlotIndex = 0
        move.ownWindowSizing = .init(size: 1.0, height: .default)
        closeLivePlace(column, toward: side, move: &move, context: context)

        rebaseLiveView(from: positionsBefore, anchoredOn: column, context: context, state: &state)
        keepLiveColumnStill(home, screenBefore: screenBefore, context: context, state: &state)
        animateLiveColumns(from: screenBefore, skipping: column, context: context, state: state)
        move.endSideDwell()
        openLiveDropSpace(
            leaving: column,
            beside: home,
            side: side,
            cursor: cursor,
            move: &move,
            context: context,
            state: &state
        )
        return true
    }

    private func detachLiveWindow(
        _ window: NiriWindow,
        from home: NiriContainer,
        at index: Int,
        sizing: NiriContainerSizingState,
        context: NiriInteractionContext
    ) -> NiriContainer {
        let column = NiriContainer()
        root(for: context.workspaceId)?.insertChild(column, at: index)
        initializeNewContainerSizing(column, in: context.workspaceId, initialState: sizing)
        moveWindowToColumn(window, from: home, to: column, in: context.workspaceId)
        if home.isTabbed, home.windowNodes.count == 1 {
            home.displayMode = .normal
            updateTabbedColumnVisibility(column: home)
        }
        home.cachedWidth = 0
        return column
    }

    private func animateLiveColumns(
        from screenBefore: [NodeId: CGFloat],
        skipping skipped: NiriContainer,
        context: NiriInteractionContext,
        state: ViewportState
    ) {
        let screenAfter = liveScreenPositions(context: context, state: state)
        for column in columns(in: context.workspaceId) where column !== skipped {
            guard let previous = screenBefore[column.id], let current = screenAfter[column.id] else { continue }
            let displacement = previous - current
            guard abs(displacement) > 0.001 else { continue }
            animateReorderedColumn(column, displacement: displacement, context: context)
        }
    }

    private func keepLiveColumnStill(
        _ column: NiriContainer,
        screenBefore: [NodeId: CGFloat],
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        guard let previous = screenBefore[column.id],
              let current = liveScreenPositions(context: context, state: state)[column.id]
        else { return }
        state.rebaseOffset(by: current - previous)
    }

    private func liveScreenPositions(context: NiriInteractionContext, state: ViewportState) -> [NodeId: CGFloat] {
        Dictionary(
            liveColumnStrip(context: context, state: state).map { ($0.column.id, $0.minX) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
