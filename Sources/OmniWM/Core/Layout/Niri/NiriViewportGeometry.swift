// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct NiriViewportGeometry {
    let gap: CGFloat
    let viewportSpan: CGFloat
    let orientation: Monitor.Orientation
    let workingArea: CGRect?
    let viewFrame: CGRect?
    let scale: CGFloat
    let edgeOverscroll: NiriEdgeOverscroll

    init(
        gap: CGFloat,
        viewportSpan: CGFloat,
        orientation: Monitor.Orientation,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil,
        scale: CGFloat = 2.0,
        edgeOverscroll: NiriEdgeOverscroll = .disabled
    ) {
        self.gap = gap
        self.viewportSpan = viewportSpan
        self.orientation = orientation
        self.workingArea = workingArea
        self.viewFrame = viewFrame
        self.scale = scale
        self.edgeOverscroll = edgeOverscroll
    }

    func overscrollBounds(columns: [NiriContainer]) -> ClosedRange<CGFloat>? {
        guard let first = columns.first, let last = columns.last else { return nil }
        let span = orientation.renderedSpanKeyPath
        let total = columns.reduce(CGFloat.zero) { $0 + $1[keyPath: span] } + CGFloat(columns.count - 1) * gap
        return edgeOverscroll.bounds(
            firstSpan: first[keyPath: span], lastSpan: last[keyPath: span], totalSpan: total,
            viewportSpan: viewportSpan, gap: gap
        )
    }
}
