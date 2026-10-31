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
              !column.windowNodes.contains(where: { $0.id == move.windowId })
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
}
