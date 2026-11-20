// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func liveColumnMoveEnd(
        releasedFrame: CGRect? = nil,
        releasedAt cursor: CGPoint? = nil,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard var move = liveColumnMove, move.workspaceId == context.workspaceId else { return false }
        restoreWidenedLiveColumn(move.carry?.widenedColumn)
        let overLanding = move.landing != nil
        if overLanding || move.home == .stackSlot {
            return endLiveMoveInPlace(
                overLanding: overLanding,
                releasedAt: releasedFrame,
                move: move,
                context: context,
                state: &state
            )
        }
        if let cursor {
            _ = liveColumnMoveUpdate(cursor: cursor, at: 0, immediate: true, context: context, state: &state)
            move = liveColumnMove ?? move
        }
        let dropSpace = liveDropSpace(for: move)
        guard let dragged = liveDraggedColumn(for: move) else {
            endLiveColumnMove()
            return true
        }

        retargetActiveColumn(to: dragged, context: context, state: &state)
        let before = primaryPositions(context: context, state: state)
        let viewBefore = liveViewPosition(positions: before, context: context, state: state)
        let landingBefore = dropSpace.flatMap { before[$0.id] }
            ?? before[dragged.id].map { $0 - (move.narrowedSlot?.leftCut ?? 0) }
        landLiveColumn(dragged, in: dropSpace, sizing: move.ownSizing, context: context)
        let releasedAt = liveReleasePosition(of: dragged, frame: releasedFrame, view: viewBefore, context: context)
        animateLiveColumnChange(
            from: before,
            anchoredOn: dragged,
            animatingAnchorFrom: releasedAt ?? landingBefore,
            context: context,
            state: &state
        )
        growLiveWindowAfterDrop(move.windowId, in: dragged, releasedAt: releasedFrame, context: context, state: state)
        let stay = viewBefore.flatMap { view in landingBefore.map { view - $0 } }
        if let settled = liveSettledOffset(
            of: dragged,
            preDragView: move.originalViewPosition,
            stayingAt: stay,
            context: context,
            state: state
        ) {
            settleLiveView(on: move.windowId, at: settled, context: context, state: &state)
        }
        state.selectedNodeId = move.windowId
        return true
    }

    private func endLiveMoveInPlace(
        overLanding: Bool,
        releasedAt releasedFrame: CGRect?,
        move: LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        if overLanding {
            return liveStackDropBegin(
                releasedAt: releasedFrame,
                move: move,
                context: context,
                state: &state
            )
        }
        return liveInStackEnd(
            releasedAt: releasedFrame,
            move: move,
            context: context,
            state: &state
        )
    }

    private func landLiveColumn(
        _ dragged: NiriContainer,
        in dropSpace: NiriContainer?,
        sizing: NiriContainerSizingState,
        context: NiriInteractionContext
    ) {
        if let dropSpace,
           let root = root(for: context.workspaceId),
           let landingIndex = root.children.firstIndex(where: { $0 === dropSpace })
        {
            root.insertChild(dragged, at: landingIndex)
        }
        endLiveColumnMove()
        dragged.isLiveHomeSpot = false
        restoreLiveSizing(sizing, to: dragged)
    }

    private func liveReleasePosition(
        of dragged: NiriContainer,
        frame releasedFrame: CGRect?,
        view viewBefore: CGFloat?,
        context: NiriInteractionContext
    ) -> CGFloat? {
        let tilesOrigin = projectedTilesOrigin(
            displayMode: dragged.displayMode,
            visibleWindowCount: projectedWindows(in: dragged, workspaceId: context.workspaceId).count
        )
        return viewBefore.flatMap { view in
            releasedFrame
                .map {
                    context.primaryStart(of: $0) - (context.orientation == .horizontal ? tilesOrigin.x : 0) - context
                        .primaryOrigin + view
                }
        }
    }

    private func liveSettledOffset(
        of dragged: NiriContainer,
        preDragView: CGFloat,
        stayingAt stay: CGFloat?,
        context: NiriInteractionContext,
        state: ViewportState
    ) -> CGFloat? {
        guard let landed = primaryPositions(context: context, state: state)[dragged.id] else { return nil }
        let preDragOffset = preDragView - landed
        let stayOffset = stay ?? state.viewOffset
        return isLiveColumnFullyVisible(
            dragged,
            atOffset: preDragOffset,
            context: context,
            state: state
        )
            ? preDragOffset
            : stayOffset
    }

    private func settleLiveView(
        on windowId: NodeId,
        at offset: CGFloat,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let final = liveDropFinalView(of: windowId, settledAt: offset, context: context, state: state)
        let columns = columns(in: context.workspaceId)
        if final.activeColumnIndex != state.activeColumnIndex, columns.indices.contains(final.activeColumnIndex) {
            retargetActiveColumn(to: columns[final.activeColumnIndex], context: context, state: &state)
        }
        state.animateToOffset(
            final.viewOffset,
            motion: context.motion,
            scale: displayScale(in: context.workspaceId)
        )
    }

    func liveDropFinalView(
        of windowId: NodeId,
        settledAt offset: CGFloat,
        context: NiriInteractionContext,
        state: ViewportState
    ) -> ViewportState {
        var settled = state
        settled.jumpOffset(to: offset)
        guard let window = findNode(by: windowId, in: context.workspaceId) else { return settled }
        settled.selectedNodeId = windowId
        ensureSelectionVisible(node: window, context: context, state: &settled)
        return settled
    }

    private func growLiveWindowAfterDrop(
        _ windowId: NodeId,
        in column: NiriContainer,
        releasedAt release: CGRect?,
        context: NiriInteractionContext,
        state: ViewportState
    ) {
        guard let release,
              let window = findNode(by: windowId, in: context.workspaceId) as? NiriWindow,
              let landed = liveWindowFrame(of: window, in: column, context: context, state: state)
        else { return }
        let start = context.orientation == .horizontal
            ? CGRect(x: landed.minX, y: release.minY, width: landed.width, height: release.height)
            : CGRect(x: release.minX, y: landed.minY, width: release.width, height: landed.height)
        animateLiveWindow(window, from: start, to: landed, leavingColumnVertically: true, context: context)
    }

    func restoreLiveSizing(_ sizing: NiriContainerSizingState, to column: NiriContainer) {
        guard containerSizingState(for: column) != sizing else { return }
        applyContainerSizingState(sizing, to: column)
    }

    func liveViewPosition(
        positions: [NodeId: CGFloat],
        context: NiriInteractionContext,
        state: ViewportState
    ) -> CGFloat? {
        let columns = columns(in: context.workspaceId)
        guard columns.indices.contains(state.activeColumnIndex),
              let activePosition = positions[columns[state.activeColumnIndex].id]
        else { return nil }
        return activePosition + state.viewOffset
    }

    func isLiveColumnFullyVisible(
        _ column: NiriContainer,
        atOffset offset: CGFloat,
        context: NiriInteractionContext,
        state: ViewportState
    ) -> Bool {
        var probe = state
        probe.viewOffset = offset
        guard let placed = liveColumnStrip(context: context, state: probe).first(where: { $0.column === column })
        else { return false }
        return placed.isFullyVisible(in: context)
    }

    func liveColumnMoveCancel(
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        assertSanctionedMutation()
        guard var move = liveColumnMove, move.workspaceId == context.workspaceId else { return false }
        guard let root = root(for: context.workspaceId), liveDraggedColumn(for: move) != nil else {
            endLiveColumnMove()
            return false
        }
        if move.landing != nil {
            placeLiveLanding(nil, move: &move, context: context, state: &state)
        }
        if let original = liveColumn(withId: move.originalSlot.columnId, in: context.workspaceId) {
            retargetActiveColumn(to: original, context: context, state: &state)
        }
        restoreLiveOriginalSlot(&move, context: context)
        liveColumnMove = move
        guard let dragged = liveDraggedColumn(for: move) else {
            endLiveColumnMove()
            return false
        }

        let before = primaryPositions(context: context, state: state)
        endLiveColumnMove()
        let columnsById = Dictionary(uniqueKeysWithValues: root.columns.map { ($0.id, $0) })
        let restoredOrder = move.originalColumnOrder.compactMap { columnsById[$0] }
        for (index, column) in restoredOrder.enumerated() {
            root.insertChild(column, at: index)
        }
        restoreLiveSizing(move.ownSizing, to: dragged)
        animateLiveColumnChange(from: before, anchoredOn: dragged, context: context, state: &state)

        let original = move.originalViewport
        let columns = columns(in: context.workspaceId)
        if let originalActive = columns.first(where: { $0.id == move.originalActiveColumnId }) {
            retargetActiveColumn(to: originalActive, context: context, state: &state)
            state.animateToOffset(
                original.viewOffset,
                motion: context.motion,
                scale: displayScale(in: context.workspaceId)
            )
        }
        state.selectedNodeId = original.selectedNodeId
        return true
    }
}
