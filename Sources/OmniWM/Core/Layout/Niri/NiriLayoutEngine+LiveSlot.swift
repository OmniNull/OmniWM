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
              !home.hasPrimarySpanAnimation(orientation: context.orientation),
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
        guard let placement = liveHomePlacement(of: move, in: strip, context: context) else { return nil }
        let span = originLiveSlotSpan(
            placement.placed,
            of: move,
            windowMidX: windowMidX,
            strip: strip,
            context: context
        )
        move.originClosedToward = span.closedToward
        return liveSlotResize(placement, minX: span.minX, width: span.width)
    }

    private func originLiveSlotSpan(
        _ placed: LiveColumnMove.StripColumn,
        of move: LiveColumnMove,
        windowMidX: CGFloat,
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext
    ) -> LiveColumnMove.SlotSpan {
        let slot = move.narrowedSlot
        let fullWidth = slot?.fullWidth ?? placed.width
        let originMinX = placed.minX - (slot?.leftCut ?? 0)
        let closedCut = max(0, fullWidth + context.gaps)
        if let closedToward = move.originClosedToward {
            return .init(
                minX: closedToward == .after ? originMinX + closedCut : originMinX,
                width: fullWidth - closedCut,
                closedToward: closedToward
            )
        }
        let shift = windowMidX - (originMinX + fullWidth / 2)
        if let index = strip.firstIndex(where: { $0.column === placed.column }) {
            let ahead = shift < 0 ? strip[..<index] : strip[(index + 1)...]
            guard ahead.contains(where: { !$0.column.isLiveDropSpace }) else {
                return .init(minX: originMinX, width: fullWidth, closedToward: nil)
            }
        }
        let cut = min(abs(shift), closedCut)
        let closed: LiveColumnMove.Side? = cut >= closedCut - 0.5 ? (shift > 0 ? .after : .before) : nil
        return .init(minX: shift > 0 ? originMinX + cut : originMinX, width: fullWidth - cut, closedToward: closed)
    }

    private func liveSlotResize(
        _ placement: (home: NiriContainer, placed: LiveColumnMove.StripColumn),
        minX: CGFloat,
        width: CGFloat
    ) -> LiveColumnMove.SlotResize? {
        guard abs(width - placement.placed.width) > 0.5 else { return nil }
        return .init(home: placement.home, placed: placement.placed, minX: minX, width: width)
    }

    func closeLivePlace(
        _ column: NiriContainer,
        toward side: LiveColumnMove.Side,
        move: inout LiveColumnMove,
        context: NiriInteractionContext
    ) {
        column.liveSlotSpan = nil
        column.setCachedPrimarySpan(0, orientation: context.orientation)
        resolvePrimaryContainerSpans(
            in: context.workspaceId,
            workingFrame: context.workingFrame,
            gaps: context.gaps,
            orientation: context.orientation
        )
        let fullWidth = column.cachedPrimarySpan(orientation: context.orientation)
        let closedCut = max(0, fullWidth + context.gaps)
        move.narrowedSlot = .init(
            columnId: column.id,
            fullWidth: fullWidth,
            orientation: context.orientation,
            leftCut: side == .after ? closedCut : 0
        )
        move.originClosedToward = side
        column.liveSlotSpan = .init(span: fullWidth - closedCut, orientation: context.orientation)
        column.setCachedPrimarySpan(fullWidth - closedCut, orientation: context.orientation)
    }

    func placeLiveSlot(
        _ resize: LiveColumnMove.SlotResize,
        in stripBefore: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> [LiveColumnMove.StripColumn]? {
        let home = resize.home
        guard var move = liveColumnMove else { return nil }
        let unchanged = (
            move: move,
            slotSpan: home.liveSlotSpan,
            cachedSpan: home.cachedPrimarySpan(orientation: context.orientation),
            state: state
        )
        let leftCut = resize.minX - resize.placed.minX
        var slot = move.narrowedSlot ?? .init(
            columnId: home.id,
            fullWidth: home.cachedPrimarySpan(orientation: context.orientation),
            orientation: context.orientation,
            leftCut: 0
        )
        slot.leftCut += leftCut
        move.narrowedSlot = slot
        move.phase = .settling
        liveColumnMove = move

        let columns = columns(in: context.workspaceId)
        let active = columns.indices.contains(state.activeColumnIndex) ? columns[state.activeColumnIndex] : home
        let before = primaryPositions(context: context, state: state)
        home.liveSlotSpan = .init(span: resize.width, orientation: context.orientation)
        home.setCachedPrimarySpan(resize.width, orientation: context.orientation)
        let after = primaryPositions(context: context, state: state)
        state.rebaseOffset(by: -((after[active.id] ?? 0) - (before[active.id] ?? 0)) - leftCut)
        let stripAfter = liveColumnStrip(context: context, state: state)
        guard stripAfter.contains(where: { $0.column === home }) else {
            liveColumnMove = unchanged.move
            home.liveSlotSpan = unchanged.slotSpan
            home.setCachedPrimarySpan(unchanged.cachedSpan, orientation: context.orientation)
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
              column.liveSlotSpan != nil
        else { return }
        if column.windowNodes.isEmpty {
            column.liveSlotSpan = nil
        } else {
            restoreLiveSlotWidth(slot, of: column)
        }
    }

    func restoreLiveSlotWidth(_ slot: LiveColumnMove.NarrowedSlot, of column: NiriContainer) {
        column.liveSlotSpan = nil
        column.setCachedPrimarySpan(slot.fullWidth, orientation: slot.orientation)
    }
}
