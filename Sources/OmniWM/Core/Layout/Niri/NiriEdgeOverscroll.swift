// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

enum NiriEdgeOverscroll: Equatable {
    case disabled
    case enabled(visibleFraction: CGFloat)

    init(allowed: Bool, visibleStripPercent: Int) {
        self = allowed ? .enabled(visibleFraction: CGFloat(visibleStripPercent) / 100) : .disabled
    }

    func bounds(
        firstSpan: CGFloat,
        lastSpan: CGFloat,
        totalSpan: CGFloat,
        viewportSpan: CGFloat,
        gap: CGFloat
    ) -> ClosedRange<CGFloat>? {
        guard case let .enabled(fraction) = self else { return nil }
        let firstVisible = min(firstSpan, viewportSpan) * fraction
        let lastVisible = min(lastSpan, viewportSpan) * fraction
        let padding = min(gap, max(0, viewportSpan - max(firstVisible, lastVisible)))
        let lower = firstVisible + padding - viewportSpan
        let upper = totalSpan - lastVisible - padding
        return min(lower, upper) ... max(lower, upper)
    }
}
