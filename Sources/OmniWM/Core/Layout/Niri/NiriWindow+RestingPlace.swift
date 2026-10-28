// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct NiriRestingPlace {
    let offset: CGFloat
    weak var column: NiriContainer?
    let heightRevision: Int
}

extension NiriWindow {
    func restingOffset(in column: NiriContainer?, room: CGFloat? = nil) -> CGFloat {
        guard sizingMode == .normal,
              let place = restingPlace,
              let column,
              place.column === column,
              place.heightRevision == heightRevision
        else { return 0 }
        guard let room else { return place.offset }
        return min(place.offset, max(0, room))
    }

    func rest(at offset: CGFloat, in column: NiriContainer) {
        restingPlace = offset > 0.5
            ? NiriRestingPlace(offset: offset, column: column, heightRevision: heightRevision)
            : nil
    }
}

extension NiriContainerLayoutFrames {
    func restingStart(
        of windows: [NiriWindow],
        in column: NiriContainer,
        spans: [NiriAxisSolver.Output],
        gap: CGFloat
    ) -> CGFloat {
        let start = secondaryStart(gap: gap)
        guard windows.count == 1, orientation == .horizontal, let span = spans.first?.value else { return start }
        return start + windows[0].restingOffset(in: column, room: secondarySpan() - 2 * gap - span)
    }
}

extension NiriLayoutEngine {
    func loneRestingOffset(
        of windows: [NiriWindow],
        in column: NiriContainer,
        spans: [NiriAxisSolver.Output],
        context: NiriInteractionContext
    ) -> CGFloat {
        guard windows.count == 1, let span = spans.first?.value else { return 0 }
        return windows[0].restingOffset(in: column, room: context.workingFrame.height - 2 * context.gaps - span)
    }
}
