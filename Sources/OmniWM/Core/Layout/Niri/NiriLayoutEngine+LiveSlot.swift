// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    private func liveHomePlacement(
        of move: LiveColumnMove,
        in strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> (home: NiriContainer, placed: LiveColumnMove.StripColumn)? {
        guard move.workspaceId == context.workspaceId,
              move.home != .stackSlot,
              let home = liveDraggedColumn(for: move),
              !home.hasWidthAnimationRunning,
              let placed = strip.first(where: { $0.column === home })
        else { return nil }
        return (home, placed)
    }

    func liveClosingSlotDecision(
        windowMidX: CGFloat,
        strip: [LiveColumnMove.StripColumn],
        move: inout LiveColumnMove,
        context: NiriInteractionContext
    ) -> LiveColumnMove.SlotResize? {
        guard let placement = liveHomePlacement(of: move, in: strip, context: context),
              move.home == .origin
        else { return nil }
        let span = originLiveSlotSpan(
            placement.placed,
            slot: move.narrowedSlot,
            windowMidX: windowMidX,
            closedToward: move.originClosedToward,
            strip: strip,
            context: context
        )
        move.originClosedToward = span.closedToward
        return liveSlotResize(placement, minX: span.minX, width: span.width, allowsGrowth: true)
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
        let distance = max(placed.width * MoveConfiguration.liveWayBackShare, MoveConfiguration.liveWayBackMinimum)
        return .init(columnId: target.id, furthestX: cursor.x, wayBack: side == .after ? -distance : distance)
    }

    func liveNarrowingDecision(
        strip: [LiveColumnMove.StripColumn],
        move: LiveColumnMove,
        context: NiriInteractionContext
    ) -> LiveColumnMove.SlotResize? {
        guard let placement = liveHomePlacement(of: move, in: strip, context: context),
              move.home == .moving
        else { return nil }
        let placed = placement.placed
        let width = liveDropSpaceWidth(context: context)
        let bounds: ClosedRange<CGFloat>
        if placed.maxX <= context.workingFrame.minX {
            bounds = placed.maxX - width ... placed.maxX
        } else if placed.minX >= context.workingFrame.maxX {
            bounds = placed.minX ... placed.minX + width
        } else {
            return nil
        }
        return liveSlotResize(
            placement,
            minX: bounds.lowerBound,
            width: bounds.upperBound - bounds.lowerBound,
            allowsGrowth: false
        )
    }

    private func liveSlotResize(
        _ placement: (home: NiriContainer, placed: LiveColumnMove.StripColumn),
        minX: CGFloat,
        width: CGFloat,
        allowsGrowth: Bool
    ) -> LiveColumnMove.SlotResize? {
        let placedWidth = placement.placed.width
        let changes = allowsGrowth ? abs(width - placedWidth) > 0.5 : width < placedWidth - 0.5
        guard changes else { return nil }
        return .init(
            home: placement.home,
            placed: placement.placed,
            minX: minX,
            width: width,
            allowsGrowth: allowsGrowth
        )
    }

    func placeLiveSlot(
        _ resize: LiveColumnMove.SlotResize,
        in stripBefore: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> [LiveColumnMove.StripColumn]? {
        let home = resize.home
        let placedWidth = resize.placed.width
        guard var move = liveColumnMove else { return nil }
        let unchanged = (move: move, slotWidth: home.liveSlotWidth, cachedWidth: home.cachedWidth, state: state)
        let leftCut = resize.minX - resize.placed.minX
        var slot = move.narrowedSlot ?? .init(columnId: home.id, fullWidth: home.cachedWidth, leftCut: 0)
        slot.leftCut += leftCut
        move.narrowedSlot = slot
        move.phase = .settling
        liveColumnMove = move

        let columns = columns(in: context.workspaceId)
        let active = columns.indices.contains(state.activeColumnIndex) ? columns[state.activeColumnIndex] : home
        let before = primaryPositions(context: context, state: state)
        home.liveSlotWidth = resize.width
        home.cachedWidth = resize.width
        let after = primaryPositions(context: context, state: state)
        state.rebaseOffset(by: -((after[active.id] ?? 0) - (before[active.id] ?? 0)) - leftCut)
        let stripAfter = liveColumnStrip(context: context, state: state)
        guard let placedHome = stripAfter.first(where: { $0.column === home }),
              resize.allowsGrowth || placedHome.width < placedWidth - 0.5
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
