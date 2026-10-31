// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

private struct LiveSlotBounds {
    let minX: CGFloat
    let maxX: CGFloat
    let next: LiveColumnMove.SlotClosing
}

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
        cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> [LiveColumnMove.StripColumn]? {
        guard let placement = liveHomePlacement(in: strip, context: context), !placement.move.stackMode
        else { return nil }
        var move = placement.move
        let placed = placement.placed
        guard let closing = move.slotClosing else {
            let picksHome = placed.minX <= cursor.x && cursor.x <= placed.maxX
            move.slotClosing = picksHome ? .pickup(x: cursor.x) : .trailing
            move.slotLeads = picksHome ? .init(left: cursor.x - placed.minX, right: placed.maxX - cursor.x) : nil
            liveColumnMove = move
            return nil
        }
        let bounds: LiveSlotBounds
        switch closing {
        case let .pickup(x):
            guard abs(cursor.x - x) > 0.5 else { return nil }
            bounds = firstLiveSlotClosing(placed, pickupX: x, leads: move.slotLeads, cursor: cursor, context: context)
        case let .following(edge) where move.swapCount == 0:
            bounds = followingLiveSlotClosing(placed, edge: edge, cursor: cursor, context: context)
        case .following,
             .trailing:
            bounds = trailingLiveSlotClosing(placed, leads: move.slotLeads, cursor: cursor, context: context)
        }
        let minX = max(placed.minX, bounds.minX)
        let maxX = min(placed.maxX, bounds.maxX)
        move.slotClosing = maxX - minX > liveDropSpaceWidth(context: context) + 0.5 ? bounds.next : .trailing
        liveColumnMove = move
        return placeLiveSlot(placement, in: strip, to: minX ... maxX, context: context, state: &state)
    }

    private func firstLiveSlotClosing(
        _ placed: LiveColumnMove.StripColumn,
        pickupX: CGFloat,
        leads: LiveColumnMove.SlotLeads?,
        cursor: CGPoint,
        context: NiriInteractionContext
    ) -> LiveSlotBounds {
        let frame = context.workingFrame
        let headingRight = cursor.x > pickupX
        let crossesRight = placed.maxX > frame.maxX + 0.5
        let crossesLeft = placed.minX < frame.minX - 0.5
        let edge: LiveColumnMove.Side
        if crossesRight, headingRight || !crossesLeft {
            edge = .after
        } else if crossesLeft {
            edge = .before
        } else {
            return trailingLiveSlotClosing(placed, leads: leads, cursor: cursor, context: context)
        }
        let width = liveDropSpaceWidth(context: context)
        let following = followingLiveSlotClosing(placed, edge: edge, cursor: cursor, context: context)
        guard (edge == .after) == headingRight else { return following }
        return edge == .after
            ? LiveSlotBounds(minX: max(placed.minX, following.maxX - width), maxX: following.maxX, next: .trailing)
            : LiveSlotBounds(minX: following.minX, maxX: min(placed.maxX, following.minX + width), next: .trailing)
    }

    private func followingLiveSlotClosing(
        _ placed: LiveColumnMove.StripColumn,
        edge: LiveColumnMove.Side,
        cursor: CGPoint,
        context: NiriInteractionContext
    ) -> LiveSlotBounds {
        let width = liveDropSpaceWidth(context: context)
        let lead = -context.gaps
        let next = LiveColumnMove.SlotClosing.following(edge: edge)
        return edge == .after
            ? LiveSlotBounds(minX: placed.minX, maxX: max(cursor.x + lead, placed.minX + width), next: next)
            : LiveSlotBounds(minX: min(cursor.x - lead, placed.maxX - width), maxX: placed.maxX, next: next)
    }

    private func trailingLiveSlotClosing(
        _ placed: LiveColumnMove.StripColumn,
        leads: LiveColumnMove.SlotLeads?,
        cursor: CGPoint,
        context: NiriInteractionContext
    ) -> LiveSlotBounds {
        guard let leads else { return LiveSlotBounds(minX: placed.minX, maxX: placed.maxX, next: .trailing) }
        let spare = max(0, placed.width - liveDropSpaceWidth(context: context))
        var leftCut = min(max(0, cursor.x - leads.left - placed.minX), spare)
        var rightCut = min(max(0, placed.maxX - cursor.x - leads.right), spare)
        if leftCut + rightCut > spare {
            if leftCut >= rightCut {
                leftCut = spare - rightCut
            } else {
                rightCut = spare - leftCut
            }
        }
        return LiveSlotBounds(minX: placed.minX + leftCut, maxX: placed.maxX - rightCut, next: .trailing)
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
        guard let placement = liveHomePlacement(in: strip, context: context) else { return false }
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
        return placeLiveSlot(placement, in: strip, to: bounds, context: context, state: &state) != nil
    }

    private func placeLiveSlot(
        _ placement: LiveHomePlacement,
        in stripBefore: [LiveColumnMove.StripColumn],
        to bounds: ClosedRange<CGFloat>,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> [LiveColumnMove.StripColumn]? {
        let home = placement.home
        guard var move = liveColumnMove, bounds.upperBound - bounds.lowerBound < placement.placed.width - 0.5
        else { return nil }
        let unchanged = (move: move, slotWidth: home.liveSlotWidth, cachedWidth: home.cachedWidth, state: state)
        let leftCut = bounds.lowerBound - placement.placed.minX
        var slot = move.narrowedSlot ?? .init(columnId: home.id, fullWidth: home.cachedWidth, leftCut: 0)
        slot.leftCut += leftCut
        move.narrowedSlot = slot
        move.phase = .settling
        liveColumnMove = move

        let columns = columns(in: context.workspaceId)
        let active = columns.indices.contains(state.activeColumnIndex) ? columns[state.activeColumnIndex] : home
        let before = primaryPositions(context: context, state: state)
        home.liveSlotWidth = bounds.upperBound - bounds.lowerBound
        home.cachedWidth = bounds.upperBound - bounds.lowerBound
        let after = primaryPositions(context: context, state: state)
        state.rebaseOffset(by: -((after[active.id] ?? 0) - (before[active.id] ?? 0)) - leftCut)
        let stripAfter = liveColumnStrip(context: context, state: state)
        guard let placedHome = stripAfter.first(where: { $0.column === home }),
              placedHome.width < placement.placed.width - 0.5
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
