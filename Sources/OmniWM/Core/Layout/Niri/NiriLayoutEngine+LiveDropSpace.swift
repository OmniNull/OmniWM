// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func applyLiveReorder(
        _ reorder: LiveColumnMove.Reorder,
        cursor: CGPoint,
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Step {
        let dragged = reorder.dragged
        let target = reorder.target
        let side = reorder.side
        switch reorder.kind {
        case let .closeDropSpace(dropSpace, revealsHome):
            closeLiveDropSpace(dropSpace, anchor: reorder.pinned, context: context, state: &state)
            move.dropSpaceId = nil
            if revealsHome {
                scrollLiveLandingUnderPointer(dragged, target: target, cursor: cursor, context: context, state: &state)
            }
            return markLiveChange(&move, target: target, side: side)
        case .openDropSpace:
            guard let opened = openLiveDropSpace(for: reorder, context: context, state: &state) else {
                return .unchanged
            }
            move.dropSpaceId = opened.id
            move.pulledStripEnd = scrollLiveLandingUnderPointer(
                opened,
                target: target,
                cursor: cursor,
                pulledEnd: move.pulledStripEnd,
                context: context,
                state: &state
            )
            return markLiveChange(&move, target: target, side: side)
        }
    }

    func liveTargetLock(
        under: NiriContainer?,
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> LiveColumnMove.TargetLock? {
        under.map { under in
            .init(
                columnId: under.id,
                side: liveTargetSide(under, cursor: cursor, strip: strip, awayFromHome: false, context: context)
            )
        }
    }

    @discardableResult
    func scrollLiveLandingUnderPointer(
        _ landing: NiriContainer,
        target: NiriContainer,
        cursor: CGPoint,
        pulledEnd: LiveColumnMove.Side? = nil,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> LiveColumnMove.Side? {
        let reveal = liveLandingReveal(
            showing: landing,
            besideTargetUnder: (target, cursor),
            strip: liveColumnStrip(context: context, state: state),
            pulledEnd: pulledEnd,
            context: context
        )
        state.animateToOffset(
            state.viewOffset + reveal.shift,
            motion: context.motion,
            scale: displayScale(in: context.workspaceId)
        )
        return reveal.pulledEnd
    }

    func closeOpenLiveDropSpace(
        move: inout LiveColumnMove,
        anchor: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        guard let dropSpace = liveDropSpace(for: move) else { return }
        closeLiveDropSpace(dropSpace, anchor: anchor, context: context, state: &state)
        move.dropSpaceId = nil
    }

    func liveLandingReveal(
        showing column: NiriContainer,
        besideTargetUnder pointer: (target: NiriContainer, cursor: CGPoint),
        strip: [LiveColumnMove.StripColumn],
        pulledEnd: LiveColumnMove.Side?,
        context: NiriInteractionContext
    ) -> (shift: CGFloat, pulledEnd: LiveColumnMove.Side?) {
        guard let landing = strip.first(where: { $0.column === column }),
              let target = strip.first(where: { $0.column === pointer.target })
        else { return (0, pulledEnd) }
        let leadingEdge = context.primaryOrigin + context.gaps
        let trailingEdge = context.primaryEnd - context.gaps
        let pull = landing.width + context.gaps
        let opensStripStart = strip.first?.column === column
        let opensStripEnd = strip.last?.column === column
        let pullsStart = column.isLiveDropSpace && opensStripStart && pulledEnd != .before
        let pullsEnd = column.isLiveDropSpace && opensStripEnd && pulledEnd != .after
        let edgeScrollReveals = liveColumnMove.map { $0.pointerInEdgeZone || $0.edgeScrollSide != nil } ?? false
        let wanted: CGFloat
        if pullsStart {
            wanted = min(-pull, landing.minX - leadingEdge)
        } else if pullsEnd {
            wanted = max(pull, landing.maxX - trailingEdge)
        } else if landing.maxX <= context.primaryOrigin || opensStripStart && landing.minX < leadingEdge - 0.5 {
            wanted = landing.minX - leadingEdge
        } else if landing.minX >= context.primaryEnd || opensStripEnd && landing.maxX > trailingEdge + 0.5 {
            wanted = landing.maxX - trailingEdge
        } else {
            return (0, pulledEnd)
        }
        let pointerX = context.primaryCoordinate(of: pointer.cursor)
        let lowest = min(0, min(landing.minX, target.minX) - pointerX)
        let highest = max(0, max(landing.maxX, target.maxX) - pointerX - 1)
        var shift = wanted.clamped(to: lowest ... highest)
        let slidesInWhole = edgeScrollReveals && (pullsStart || pullsEnd)
        if !slidesInWhole, liveCentreThird(of: target, context: context)?.contains(pointerX) != true {
            shift = liveShiftKeepingPointerOutOfCentre(shift, target: target, pointerX: pointerX, context: context)
        }
        if pullsStart, shift < -0.5 {
            return (shift, .before)
        }
        if pullsEnd, shift > 0.5 {
            return (shift, .after)
        }
        return (shift, pulledEnd)
    }

    private func liveShiftKeepingPointerOutOfCentre(
        _ shift: CGFloat,
        target: LiveColumnMove.StripColumn,
        pointerX: CGFloat,
        context: NiriInteractionContext
    ) -> CGFloat {
        func keepsOut(_ candidate: CGFloat) -> Bool {
            liveCentreThird(of: target, shiftedBy: candidate, context: context)?.contains(pointerX + candidate) != true
        }
        guard !keepsOut(shift) else { return shift }
        var allowed: CGFloat = 0
        var refused = shift
        while abs(refused - allowed) > 0.5 {
            let middle = (allowed + refused) / 2
            if keepsOut(middle) { allowed = middle } else { refused = middle }
        }
        return allowed
    }

    func liveDropSpaceWidth(context: NiriInteractionContext) -> CGFloat {
        min(
            context.primarySpan * MoveConfiguration.liveDropSpaceShare,
            MoveConfiguration.liveDropSpaceMaximumWidth
        )
    }

    private func markLiveChange(
        _ move: inout LiveColumnMove,
        target: NiriContainer,
        side: LiveColumnMove.Side
    ) -> LiveColumnMove.Step {
        move.lockedTarget = .init(columnId: target.id, side: side)
        move.phase = .settling
        return .changed
    }

    func liveDropSpace(for move: LiveColumnMove) -> NiriContainer? {
        guard let dropSpaceId = move.dropSpaceId else { return nil }
        return liveColumn(withId: dropSpaceId, in: move.workspaceId)
    }

    @inline(__always)
    private func openLiveDropSpace(
        for reorder: LiveColumnMove.Reorder,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriContainer? {
        guard case let .openDropSpace(existing, target) = reorder.kind,
              let root = root(for: context.workspaceId),
              root.children.contains(where: { $0 === target }),
              root.children.contains(where: { $0 === reorder.pinned })
        else { return nil }
        retargetActiveColumn(to: reorder.pinned, context: context, state: &state)
        let before = primaryPositions(context: context, state: state)
        let dropSpace = existing ?? {
            let column = NiriContainer()
            column.isLiveDropSpace = true
            if context.orientation == .horizontal {
                column.width = .fixed(liveDropSpaceWidth(context: context))
            } else {
                column.height = .fixed(liveDropSpaceWidth(context: context))
            }
            return column
        }()
        dropSpace.detach()
        guard let targetIndex = root.children.firstIndex(where: { $0 === target }) else { return nil }
        root.insertChild(dropSpace, at: reorder.side == .before ? targetIndex : targetIndex + 1)
        dropSpace.setCachedPrimarySpan(0, orientation: context.orientation)
        animateLivePinnedChange(from: before, pinning: reorder.pinned, context: context, state: &state)
        return dropSpace
    }

    private func closeLiveDropSpace(
        _ dropSpace: NiriContainer,
        anchor: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        retargetActiveColumn(to: anchor, context: context, state: &state)
        let before = primaryPositions(context: context, state: state)
        dropSpace.remove()
        animateLivePinnedChange(from: before, pinning: anchor, context: context, state: &state)
    }

    func animateLivePinnedChange(
        from before: [NodeId: CGFloat],
        pinning pinned: NiriContainer,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        if let index = columnIndex(of: pinned, in: context.workspaceId) {
            state.activeColumnIndex = index
        }
        let after = primaryPositions(context: context, state: state)
        let drift = (after[pinned.id] ?? 0) - (before[pinned.id] ?? 0)
        for column in columns(in: context.workspaceId) {
            guard let previous = before[column.id], let current = after[column.id] else { continue }
            let displacement = previous - current + drift
            guard abs(displacement) > 0.001 else { continue }
            animateReorderedColumn(column, displacement: displacement, context: context)
        }
    }

    func liveColumnMoveHop(
        towardTrailingEdge: Bool,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> NiriContainer? {
        guard var move = liveColumnMove,
              move.workspaceId == context.workspaceId,
              move.home != .stackSlot,
              let dragged = liveDraggedColumn(for: move),
              let root = root(for: context.workspaceId)
        else { return nil }
        defer { replaceLiveColumnMove(with: move) }
        let hinted = move.landing.flatMap { liveColumn(withId: $0.columnId, in: move.workspaceId) }
        if move.landing != nil {
            closeLiveLandingHint(move: &move, context: context, state: &state)
        }
        let dropSpace = liveDropSpace(for: move)
        let side: LiveColumnMove.Side = towardTrailingEdge ? .after : .before
        let columns = root.children.compactMap { $0 as? NiriContainer }
        guard let anchorIndex = columns.firstIndex(where: { $0 === (dropSpace ?? dragged) }) else { return nil }
        let primaryOrigin = context.primaryOrigin
        let primaryEnd = context.primaryEnd
        let placedById = liveColumnsByIdentity(context: context, state: state)
        let placedColumn: (NiriContainer) -> LiveColumnMove.StripColumn? = { placedById[ObjectIdentifier($0)] }
        let isWindow: (NiriContainer) -> Bool = {
            $0 !== dragged && !$0.isLiveDropSpace && placedColumn($0) != nil
        }
        let homeBeyondView = dropSpace == nil && hinted == nil && placedColumn(dragged).map { home in
            towardTrailingEdge ? home.minX >= primaryEnd - 0.5 : home.maxX <= primaryOrigin + 0.5
        } == true
        let ahead = liveColumnsAhead(of: anchorIndex, in: columns, wholeStrip: homeBeyondView, toward: side)
        let behindView: (LiveColumnMove.StripColumn) -> Bool = towardTrailingEdge
            ? { $0.maxX <= primaryOrigin + 0.5 }
            : { $0.minX >= primaryEnd - 0.5 }
        let onScreen: (LiveColumnMove.StripColumn) -> Bool = {
            $0.maxX > primaryOrigin + 0.5 && $0.minX < primaryEnd - 0.5
        }
        let windowsAhead = ahead.filter(isWindow).drop { placedColumn($0).map(behindView) ?? false }
        let reachable = windowsAhead.prefix { placedColumn($0).map(onScreen) ?? false }
        let passed = hinted ?? reachable.last ?? windowsAhead.first
        let hopsBesideHome = dropSpace == nil && move.originClosedToward != nil
        guard let beside = passed ?? (hopsBesideHome ? dragged : nil) else { return nil }
        let reorder = LiveColumnMove.Reorder(
            dragged: dragged,
            target: beside,
            side: side,
            pinned: beside,
            kind: .openDropSpace(existing: dropSpace, beside: beside)
        )
        guard let opened = openLiveDropSpace(for: reorder, context: context, state: &state) else { return nil }
        move.dropSpaceId = opened.id
        revealLiveDropSpace(opened, toward: side, context: context, state: &state)
        move.endSideDwell()
        _ = markLiveChange(&move, target: beside, side: side)
        return beside
    }

    private func liveColumnsByIdentity(
        context: NiriInteractionContext,
        state: ViewportState
    ) -> [ObjectIdentifier: LiveColumnMove.StripColumn] {
        Dictionary(
            liveColumnStrip(context: context, state: state).map { (ObjectIdentifier($0.column), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func liveColumnsAhead(
        of anchorIndex: Int,
        in columns: [NiriContainer],
        wholeStrip: Bool,
        toward side: LiveColumnMove.Side
    ) -> [NiriContainer] {
        if wholeStrip {
            side == .after ? columns : columns.reversed()
        } else if side == .after {
            Array(columns[(anchorIndex + 1)...])
        } else {
            Array(columns[..<anchorIndex].reversed())
        }
    }

    private func revealLiveDropSpace(
        _ opened: NiriContainer,
        toward side: LiveColumnMove.Side,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let shift = liveEdgeRevealShift(
            showing: opened,
            checking: [side],
            slack: 0.5,
            strip: liveColumnStrip(context: context, state: state),
            context: context
        )
        animateLiveViewShift(shift, context: context, state: &state)
    }
}
