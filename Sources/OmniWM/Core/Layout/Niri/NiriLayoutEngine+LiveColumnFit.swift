// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
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
}
