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
        liveColumn(in: strip, at: cursor, ignoring: dropSpace, context: context)
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
              context.primaryCoordinate(of: cursor) >= context.primaryOrigin,
              context.primaryCoordinate(of: cursor) <= context.primaryEnd
        else { return nil }
        if context.primaryCoordinate(of: cursor) >= last.maxX { return last.column }
        if context.primaryCoordinate(of: cursor) < first.minX { return first.column }
        return nil
    }
}
