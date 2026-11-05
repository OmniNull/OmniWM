// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func liveColumn(
        _ column: NiriContainer,
        fitsWidthOf window: NiriWindow,
        strip: [LiveColumnMove.StripColumn]
    ) -> Bool {
        guard let placed = strip.first(where: { $0.column === column }) else { return false }
        let needed = window.constraints.normalized().minSize.width + tabContentInset(for: column)
        return needed <= placed.maxX - placed.minX + FrameTolerance.screenMatch
    }

    func liveColumnOrStripEnd(
        in strip: [LiveColumnMove.StripColumn],
        at cursor: CGPoint,
        ignoring dropSpace: NiriContainer?,
        context: NiriInteractionContext
    ) -> NiriContainer? {
        liveColumn(in: strip, at: cursor, ignoring: dropSpace)
            ?? liveColumnPastStripEnd(in: strip, at: cursor, ignoring: dropSpace, context: context)
    }

    private func liveColumnPastStripEnd(
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
        guard liveColumnPastStripEnd(
            in: liveColumnStrip(context: context, state: state),
            at: cursor,
            ignoring: liveDropSpace(for: move),
            context: context
        ) != nil else { return }
        move.stackMode = false
        move.awaitsPointerMoveFrom = nil
        if move.inStack {
            stepLiveColumnMove(to: cursor, move: &move, context: context, state: &state)
        }
        if !move.inStack {
            stepLiveColumnMove(to: cursor, move: &move, context: context, state: &state)
        }
    }

    private func stepLiveColumnMove(
        to cursor: CGPoint,
        move: inout LiveColumnMove,
        context: NiriInteractionContext,
        state: inout ViewportState
    ) {
        liveColumnMove = move
        _ = liveColumnMoveUpdate(cursor: cursor, at: 0, immediate: true, context: context, state: &state)
        if let updated = liveColumnMove {
            move = updated
        }
    }
}
