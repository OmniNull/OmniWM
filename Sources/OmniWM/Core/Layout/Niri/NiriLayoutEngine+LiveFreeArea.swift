// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func liveFreeArea(
        at cursor: CGPoint,
        strip: [LiveColumnMove.StripColumn],
        move: LiveColumnMove,
        context: NiriInteractionContext
    ) -> LiveColumnMove.FreeArea? {
        guard !move.isWholeColumn,
              let column = liveColumn(in: strip, at: cursor, ignoring: liveDropSpace(for: move)),
              column.id != move.homeColumnId,
              !column.isTabbed,
              !column.isLiveDropSpace,
              !column.isLiveHomeSpot,
              !column.windowNodes.contains(where: { $0.id == move.windowId }),
              let window = findNode(by: move.windowId, in: move.workspaceId) as? NiriWindow,
              liveColumn(column, fitsWidthOf: window, strip: strip)
        else { return nil }
        let spans = liveWindowSpans(in: column, context: context)
        guard let lowest = spans.first, let highest = spans.last else { return nil }
        let minimum = moveConfiguration.liveFreeAreaMinimumHeight
        let roomAbove = context.workingFrame.maxY - context.gaps - (highest.maxY + context.gaps)
        if cursor.y >= highest.maxY, roomAbove >= minimum {
            return .init(
                landing: .init(columnId: column.id, targetWindowId: highest.window.id, above: true),
                height: roomAbove
            )
        }
        let roomBelow = lowest.minY - context.gaps - (context.workingFrame.minY + context.gaps)
        if cursor.y < lowest.minY, roomBelow >= minimum {
            return .init(
                landing: .init(columnId: column.id, targetWindowId: lowest.window.id, above: false),
                height: roomBelow
            )
        }
        return nil
    }

    func liveColumnMoveDropIntoFreeArea(
        at cursor: CGPoint,
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) -> Bool {
        let strip = liveColumnStrip(context: context, state: state)
        guard let area = liveFreeArea(at: cursor, strip: strip, move: move, context: context) else { return false }
        return placeLiveLanding(area.landing, height: area.height, move: &move, context: context, state: &state)
    }

    func liveColumn(
        _ column: NiriContainer,
        fitsWidthOf window: NiriWindow,
        strip: [LiveColumnMove.StripColumn]
    ) -> Bool {
        guard let placed = strip.first(where: { $0.column === column }) else { return false }
        let needed = window.constraints.normalized().minSize.width + tabContentInset(for: column)
        return needed <= placed.maxX - placed.minX + FrameTolerance.screenMatch
    }

    func liveColumnPastStripEnd(
        in strip: [LiveColumnMove.StripColumn],
        at cursor: CGPoint,
        ignoring dropSpace: NiriContainer?,
        context: NiriInteractionContext
    ) -> NiriContainer? {
        let placed = strip.filter { $0.column !== dropSpace }
        guard let first = placed.first, let last = placed.last,
              cursor.x >= context.workingFrame.minX, cursor.x <= context.workingFrame.maxX
        else { return nil }
        if cursor.x >= last.maxX { return last.column }
        if cursor.x < first.minX { return first.column }
        return nil
    }

    func liveColumnMoveToStripEnd(
        at cursor: CGPoint,
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        let strip = liveColumnStrip(context: context, state: state)
        let dropSpace = liveDropSpace(for: move)
        guard liveColumn(in: strip, at: cursor, ignoring: dropSpace) == nil,
              liveColumnPastStripEnd(in: strip, at: cursor, ignoring: dropSpace, context: context) != nil
        else { return }
        move.stackMode = false
        move.awaitsPointerMoveFrom = nil
        for _ in 0 ..< 2 {
            liveColumnMove = move
            _ = liveColumnMoveUpdate(cursor: cursor, at: 0, immediate: true, context: context, state: &state)
            guard let updated = liveColumnMove else { return }
            move = updated
        }
    }
}
