// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func liveColumnOrStripEnd(
        in strip: [LiveColumnMove.StripColumn],
        at cursor: CGPoint,
        ignoring dropSpace: NiriContainer?,
        closedHome: NiriContainer?,
        context: NiriInteractionContext
    ) -> NiriContainer? {
        let primary = context.primaryCoordinate(of: cursor)
        if let match = strip.first(where: {
            $0.column !== dropSpace && $0.column !== closedHome && $0.contains(x: primary)
        }) {
            return match.column
        }
        guard primary >= context.primaryOrigin, primary <= context.primaryEnd else { return nil }
        if let last = strip.last(where: { $0.column !== dropSpace && $0.column !== closedHome }), primary >= last.maxX {
            return last.column
        }
        if let first = strip.first(where: { $0.column !== dropSpace && $0.column !== closedHome }),
           primary < first.minX
        {
            return first.column
        }
        return nil
    }
}
