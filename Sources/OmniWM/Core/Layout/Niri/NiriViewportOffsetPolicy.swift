// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct NiriViewportVisibility {
    let index: Int
    let count: Int
    let position: CGFloat
    let fromIndex: Int?
    let viewStart: CGFloat
    let centerMode: CenterFocusedColumn
    let edges: ViewportEdgeRules
}

extension NiriViewportGeometry {
    @inline(__always)
    func visibleOffset(
        _ request: NiriViewportVisibility,
        mode: @autoclosure () -> SizingMode,
        positionAt: (Int) -> CGFloat,
        spanAt: (Int) -> CGFloat
    ) -> CGFloat {
        if request.edges.centersFittingStrip, let start = ViewportState.centredStripOffset(
            stripSpan: stripSpan(count: request.count, spanAt: spanAt), viewSpan: viewportSpan, gap: gap, scale: scale
        ) {
            return start - request.position
        }
        let target = ViewportColumnTarget(
            index: request.index, position: request.position, span: spanAt(request.index), mode: mode(),
            columnCount: request.count
        )
        var areas = ViewportFittingAreas(geometry: self)
        areas.edgePeeks = request.edges.peeks
        let shouldCenter = switch request.centerMode {
        case .always: true
        case .never: false
        case .onOverflow: shouldCenterAdjacentPair(
                target, fromIndex: request.fromIndex, workingSpan: areas.span(of: areas.working),
                positionAt: positionAt, spanAt: spanAt
            )
        }
        var offset = shouldCenter
            ? areas.centeredOffset(currentViewStart: request.viewStart, target: target, gap: gap)
            : areas.fitOffset(currentViewStart: request.viewStart, target: target, gap: gap)
        guard target.mode == .normal else { return offset }
        if request.edges.keepsStripEndsOnScreen, request.centerMode != .always,
           let range = ViewportState.stripEndOffsets(
               stripSpan: stripSpan(count: request.count, spanAt: spanAt),
               viewSpan: viewportSpan,
               gap: gap
           )
        {
            offset = (request.position + offset).clamped(to: range) - request.position
        }
        return areas.offsetShowingEdgePeeks(
            offset, target: target, spans: (0 ..< request.count).map(spanAt), gap: gap
        )
    }

    @inline(__always)
    func stripSpan(count: Int, spanAt: (Int) -> CGFloat) -> CGFloat {
        var span: CGFloat = 0
        for index in 0 ..< count {
            span += spanAt(index)
        }
        return span + CGFloat(max(count - 1, 0)) * gap
    }

    @inline(__always)
    private func shouldCenterAdjacentPair(
        _ target: ViewportColumnTarget, fromIndex: Int?, workingSpan: CGFloat,
        positionAt: (Int) -> CGFloat, spanAt: (Int) -> CGFloat
    ) -> Bool {
        guard let fromIndex, fromIndex != target.index, (0 ..< target.columnCount).contains(fromIndex)
        else { return false }
        let sourceIndex = fromIndex > target.index ? target.index + 1 : target.index - 1
        let sourcePosition = positionAt(sourceIndex)
        let sourceSpan = spanAt(sourceIndex)
        let pairSpan = if sourcePosition < target.position {
            target.position - sourcePosition + target.span
        } else {
            sourcePosition - target.position + sourceSpan
        }
        return (pairSpan + gap * 2).roundedToPhysicalPixel(scale: scale)
            > workingSpan.roundedToPhysicalPixel(scale: scale)
    }
}

struct NiriViewportSettle {
    let activePosition: CGFloat
    let viewStart: CGFloat
    let viewportSpan: CGFloat
    let gap: CGFloat
    let centerMode: CenterFocusedColumn
    let keepsStripEndsOnScreen: Bool
    let preservesCenteredView: Bool

    @inline(__always)
    func correction(
        overscrollBounds: ClosedRange<CGFloat>?,
        centersStrip: @autoclosure () -> Bool,
        stripSpan: () -> CGFloat,
        adjacentPairOverflows: () -> Bool,
        visibleOffset: (_ proposedStart: CGFloat, _ mode: CenterFocusedColumn, _ usesEdges: Bool) -> CGFloat
    ) -> CGFloat? {
        if let overscrollBounds {
            let bounded = viewStart.clamped(to: overscrollBounds)
            return abs(bounded - viewStart) > 0.5 ? bounded - activePosition : nil
        }
        if centerMode == .always || centersStrip() {
            return changedOffset(visibleOffset(viewStart, centerMode, true))
        }

        let contentEdge = stripSpan() - viewportSpan + gap
        let clampedStart = viewStart.clamped(to: min(-gap, contentEdge) ... max(-gap, contentEdge))
        guard abs(clampedStart - viewStart) > 0.5 else { return nil }
        if !keepsStripEndsOnScreen, preservesCenteredView || (centerMode == .onOverflow && adjacentPairOverflows()),
           abs(activePosition + visibleOffset(viewStart, .always, false) - viewStart) <= 0.5
        {
            return nil
        }
        return changedOffset(visibleOffset(clampedStart, .never, false))
    }

    private func changedOffset(_ offset: CGFloat) -> CGFloat? {
        abs(activePosition + offset - viewStart) > 0.5 ? offset : nil
    }
}

extension ViewportState {
    static func visibilityCorrection(from offset: CGFloat, to target: CGFloat, scale: CGFloat) -> CGFloat? {
        abs(target - offset) <= 1 / max(scale, 1) ? nil : target
    }
}

extension NiriResolvedScrollStrip {
    func scrollTarget(
        _ offset: CGFloat, geometry: NiriViewportGeometry, settings: ResolvedNiriSettings,
        edges: ViewportEdgeRules, reconcile: NiriScrollReconcile
    ) -> CGFloat? {
        let span = geometry.stripSpan(count: columns.count, spanAt: { columns[$0].span })
        let active = columns[activeIndex]
        let bounds = geometry.edgeOverscroll.bounds(
            firstSpan: columns[0].span, lastSpan: columns[columns.count - 1].span, totalSpan: span,
            viewportSpan: geometry.viewportSpan, gap: geometry.gap
        )
        let ends = -geometry.gap ... max(-geometry.gap, span - geometry.viewportSpan + geometry.gap)
        let clampedStart = (active.position + offset).clamped(to: bounds ?? ends)
        let target = clampedStart - active.position
        if settings.edgeOverscroll == .disabled, !reconcile.keepsClickedSelectionOffscreen {
            let visible = visibleOffset(
                from: clampedStart, in: geometry, centerMode: settings.centerFocusedColumn, edges: edges,
                centersSingleColumn: settings.alwaysCenterSingleColumn
            )
            if ViewportState.visibilityCorrection(from: target, to: visible, scale: geometry.scale) != nil {
                return nil
            }
        }
        guard reconcile.settlesUnprojectedStrip else { return target }
        let settle = NiriViewportSettle(
            activePosition: active.position, viewStart: clampedStart,
            viewportSpan: geometry.viewportSpan, gap: geometry.gap,
            centerMode: settings.centerFocusedColumn, keepsStripEndsOnScreen: edges.keepsStripEndsOnScreen,
            preservesCenteredView: true
        )
        let correction = settle.correction(
            overscrollBounds: bounds,
            centersStrip: settings.alwaysCenterSingleColumn && (columns.count == 1 || edges.centersFittingStrip
                && ViewportState.centredStripOffset(
                    stripSpan: span, viewSpan: geometry.viewportSpan, gap: geometry.gap, scale: geometry.scale
                ) != nil),
            stripSpan: { span },
            adjacentPairOverflows: { false },
            visibleOffset: { start, mode, usesEdges in
                visibleOffset(
                    from: start, in: geometry, centerMode: mode, edges: usesEdges ? edges : .init(),
                    centersSingleColumn: usesEdges && settings.alwaysCenterSingleColumn
                )
            }
        )
        return correction == nil ? target : nil
    }

    private func visibleOffset(
        from viewStart: CGFloat, in geometry: NiriViewportGeometry, centerMode: CenterFocusedColumn,
        edges: ViewportEdgeRules, centersSingleColumn: Bool
    ) -> CGFloat {
        geometry.visibleOffset(
            .init(
                index: activeIndex, count: columns.count, position: columns[activeIndex].position,
                fromIndex: activeIndex, viewStart: viewStart,
                centerMode: centersSingleColumn && columns.count == 1 ? .always : centerMode, edges: edges
            ),
            mode: activeMode,
            positionAt: { columns[$0].position },
            spanAt: { columns[$0].span }
        )
    }
}

struct NiriScrollReconcile {
    let keepsClickedSelectionOffscreen: Bool
    let settlesUnprojectedStrip: Bool
}
