// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

private struct LiveHomePlacement {
    let move: LiveColumnMove
    let home: NiriContainer
    let placed: LiveColumnMove.StripColumn
}

extension NiriLayoutEngine {
    private func liveHomePlacement(
        in strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> LiveHomePlacement? {
        guard let move = liveColumnMove,
              move.workspaceId == context.workspaceId,
              !move.inStack,
              let home = liveDraggedColumn(for: move),
              !home.hasWidthAnimationRunning,
              let placed = strip.first(where: { $0.column === home })
        else { return nil }
        return LiveHomePlacement(move: move, home: home, placed: placed)
    }

    func closeLiveSlotAroundPointer(
        windowMidX: CGFloat,
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> [LiveColumnMove.StripColumn]? {
        guard let placement = liveHomePlacement(in: strip, context: context),
              isClosingOrigin(placement.move)
        else { return nil }
        var move = placement.move
        let placed = placement.placed
        let span = originLiveSlotSpan(
            placed,
            slot: move.narrowedSlot,
            windowMidX: windowMidX,
            closedToward: move.originClosedToward,
            strip: strip,
            context: context
        )
        move.originClosedToward = span.closedToward
        liveColumnMove = move
        return placeLiveSlot(
            placement,
            in: strip,
            to: (span.minX, span.width),
            allowsGrowth: true,
            context: context,
            state: &state
        )
    }

    func isClosingOrigin(_ move: LiveColumnMove) -> Bool {
        move.carry == nil && !move.inStack && move.homeColumnId == move.originalSlot.columnId
    }

    private func originLiveSlotSpan(
        _ placed: LiveColumnMove.StripColumn,
        slot: LiveColumnMove.NarrowedSlot?,
        windowMidX: CGFloat,
        closedToward: LiveColumnMove.Side?,
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> (minX: CGFloat, width: CGFloat, closedToward: LiveColumnMove.Side?) {
        let fullWidth = slot?.fullWidth ?? placed.width
        let originMinX = placed.minX - (slot?.leftCut ?? 0)
        let closedCut = max(0, fullWidth + context.gaps)
        if let closedToward {
            return (closedToward == .after ? originMinX + closedCut : originMinX, fullWidth - closedCut, closedToward)
        }
        let shift = windowMidX - (originMinX + fullWidth / 2)
        if let index = strip.firstIndex(where: { $0.column === placed.column }) {
            let ahead = shift < 0 ? strip[..<index] : strip[(index + 1)...]
            guard ahead.contains(where: { !$0.column.isLiveDropSpace }) else { return (originMinX, fullWidth, nil) }
        }
        let cut = min(abs(shift), closedCut)
        let closed: LiveColumnMove.Side? = cut >= closedCut - 0.5 ? (shift > 0 ? .after : .before) : nil
        return (shift > 0 ? originMinX + cut : originMinX, fullWidth - cut, closed)
    }

    func livePassed(
        _ target: NiriContainer,
        side: LiveColumnMove.Side,
        strip: [LiveColumnMove.StripColumn],
        cursor: CGPoint
    ) -> LiveColumnMove.Passed? {
        guard let placed = strip.first(where: { $0.column === target }) else { return nil }
        let distance = max(placed.width * moveConfiguration.liveWayBackShare, moveConfiguration.liveWayBackMinimum)
        return .init(columnId: target.id, furthestX: cursor.x, wayBack: side == .after ? -distance : distance)
    }

    func sideBySideVisibleColumns(
        around home: NiriContainer,
        context: NiriInteractionContext,
        state: ViewportState
    ) -> Set<NodeId> {
        let frame = context.workingFrame
        let visible = Set(
            liveColumnStrip(context: context, state: state)
                .filter { $0.isFullyVisible(in: frame) }
                .map(\.column.id)
        )
        guard visible.contains(home.id) else { return [] }
        let neighbours = [home.prevSibling(), home.nextSibling()].compactMap { $0 as? NiriContainer }
        return Set(neighbours.map(\.id).filter { visible.contains($0) })
    }

    func narrowOffScreenHomeSlot(
        strip: [LiveColumnMove.StripColumn]? = nil,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        let strip = strip ?? liveColumnStrip(context: context, state: state)
        guard let placement = liveHomePlacement(in: strip, context: context),
              !isClosingOrigin(placement.move)
        else { return false }
        let placed = placement.placed
        let width = liveDropSpaceWidth(context: context)
        let bounds: ClosedRange<CGFloat>
        if placed.maxX <= context.workingFrame.minX {
            bounds = placed.maxX - width ... placed.maxX
        } else if placed.minX >= context.workingFrame.maxX {
            bounds = placed.minX ... placed.minX + width
        } else {
            return false
        }
        return placeLiveSlot(
            placement,
            in: strip,
            to: (bounds.lowerBound, bounds.upperBound - bounds.lowerBound),
            context: context,
            state: &state
        ) != nil
    }

    private func placeLiveSlot(
        _ placement: LiveHomePlacement,
        in stripBefore: [LiveColumnMove.StripColumn],
        to span: (minX: CGFloat, width: CGFloat),
        allowsGrowth: Bool = false,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> [LiveColumnMove.StripColumn]? {
        let home = placement.home
        let placedWidth = placement.placed.width
        let changes = allowsGrowth ? abs(span.width - placedWidth) > 0.5 : span.width < placedWidth - 0.5
        guard var move = liveColumnMove, changes else { return nil }
        let unchanged = (move: move, slotWidth: home.liveSlotWidth, cachedWidth: home.cachedWidth, state: state)
        let leftCut = span.minX - placement.placed.minX
        var slot = move.narrowedSlot ?? .init(columnId: home.id, fullWidth: home.cachedWidth, leftCut: 0)
        slot.leftCut += leftCut
        move.narrowedSlot = slot
        move.phase = .settling
        liveColumnMove = move

        let columns = columns(in: context.workspaceId)
        let active = columns.indices.contains(state.activeColumnIndex) ? columns[state.activeColumnIndex] : home
        let before = primaryPositions(context: context, state: state)
        home.liveSlotWidth = span.width
        home.cachedWidth = span.width
        let after = primaryPositions(context: context, state: state)
        state.rebaseOffset(by: -((after[active.id] ?? 0) - (before[active.id] ?? 0)) - leftCut)
        let stripAfter = liveColumnStrip(context: context, state: state)
        guard let placedHome = stripAfter.first(where: { $0.column === home }),
              allowsGrowth || placedHome.width < placedWidth - 0.5
        else {
            liveColumnMove = unchanged.move
            home.liveSlotWidth = unchanged.slotWidth
            home.cachedWidth = unchanged.cachedWidth
            state = unchanged.state
            return nil
        }
        for placed in stripAfter where placed.column !== home {
            guard let previous = stripBefore.first(where: { $0.column === placed.column }),
                  abs(previous.minX - placed.minX) > 0.001
            else { continue }
            animateReorderedColumn(placed.column, displacement: previous.minX - placed.minX, context: context)
        }
        return stripAfter
    }

    func widenLiveSlot(_ slot: LiveColumnMove.NarrowedSlot, in workspaceId: WorkspaceDescriptor.ID?) {
        guard let workspaceId,
              let column = columns(in: workspaceId).first(where: { $0.id == slot.columnId }),
              column.liveSlotWidth != nil
        else { return }
        if column.windowNodes.isEmpty {
            column.liveSlotWidth = nil
        } else {
            restoreLiveSlotWidth(slot, of: column)
        }
    }

    func restoreLiveSlotWidth(_ slot: LiveColumnMove.NarrowedSlot, of column: NiriContainer) {
        column.liveSlotWidth = nil
        column.cachedWidth = slot.fullWidth
    }
}
