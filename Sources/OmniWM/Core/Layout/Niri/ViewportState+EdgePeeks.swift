// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension ViewportFittingAreas {
    func fittingArea(for target: ViewportColumnTarget) -> CGRect {
        let area = area(for: target.mode)
        guard let edgePeeks, orientation == .horizontal, target.mode == .normal else { return area }
        let leading = target.index > 0 && edgePeeks.leading > 0
            ? max(0, parent.minX + edgePeeks.leading - area.minX)
            : 0
        let trailing = target.index < target.columnCount - 1 && edgePeeks.trailing > 0
            ? max(0, area.maxX - (parent.maxX - edgePeeks.trailing))
            : 0
        guard area.width - leading - trailing > target.span else { return area }
        return CGRect(
            x: area.minX + leading,
            y: area.minY,
            width: area.width - leading - trailing,
            height: area.height
        )
    }

    func viewStartShowingEdgePeeks(_ viewStart: CGFloat, spans: [CGFloat], gap: CGFloat) -> CGFloat? {
        guard let edgePeeks, orientation == .horizontal, spans.count > 1 else { return viewStart }
        let pixel = 1.0 / max(scale, 1.0)
        let missing = missingEdgePeeks(at: viewStart, spans: spans, gap: gap, peeks: edgePeeks)
        let needsLeading = missing.leading > pixel
        let needsTrailing = missing.trailing > pixel
        guard needsLeading || needsTrailing else { return viewStart }
        guard needsLeading != needsTrailing else { return nil }
        let corrected = needsLeading ? viewStart - missing.leading : viewStart + missing.trailing
        let remaining = missingEdgePeeks(at: corrected, spans: spans, gap: gap, peeks: edgePeeks)
        guard remaining.leading <= pixel, remaining.trailing <= pixel else { return nil }
        return corrected
    }

    func missingEdgePeeks(
        at viewStart: CGFloat,
        spans: [CGFloat],
        gap: CGFloat,
        peeks: EdgePeekWidths
    ) -> (leading: CGFloat, trailing: CGFloat) {
        let pixel = 1.0 / max(scale, 1.0)
        let leadingEdge = viewStart + parent.minX
        let trailingEdge = viewStart + parent.maxX
        var leading: CGFloat = 0
        var trailing: CGFloat?
        var start: CGFloat = 0
        for span in spans {
            let end = start + span
            if peeks.leading > 0, start < leadingEdge - pixel {
                leading = max(0, min(peeks.leading, span) - (end - leadingEdge))
            }
            if peeks.trailing > 0, trailing == nil, end > trailingEdge + pixel {
                trailing = max(0, min(peeks.trailing, span) - (trailingEdge - start))
            }
            start = end + gap
        }
        return (leading, trailing ?? 0)
    }
}

extension ViewportFittingAreas {
    func nearestViewStartShowingEdgePeeks(
        _ viewStart: CGFloat,
        spans: [CGFloat],
        gap: CGFloat,
        within range: ClosedRange<CGFloat>
    ) -> CGFloat? {
        if let corrected = viewStartShowingEdgePeeks(viewStart, spans: spans, gap: gap),
           range.contains(corrected)
        {
            return corrected
        }
        guard let edgePeeks, let widest = spans.max() else { return nil }
        let pixel = 1.0 / max(scale, 1.0)
        var distance: CGFloat = 1
        while distance <= widest + gap {
            for candidate in [viewStart - distance, viewStart + distance] where range.contains(candidate) {
                let missing = missingEdgePeeks(at: candidate, spans: spans, gap: gap, peeks: edgePeeks)
                if missing.leading <= pixel, missing.trailing <= pixel {
                    return candidate
                }
            }
            distance += 1
        }
        return nil
    }
}

extension ViewportState {
    func viewStartRestoringEdgePeeks(
        _ viewStart: CGFloat,
        columns: [NiriContainer],
        areas: ViewportFittingAreas,
        gap: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>
    ) -> CGFloat {
        guard areas.edgePeeks != nil, columns.count > 1 else { return viewStart }
        let spans = columns.map { $0[keyPath: sizeKeyPath] }
        let stripEnd = totalSpan(containers: columns, gap: gap, sizeKeyPath: sizeKeyPath)
        let earliest = min(viewStart, -gap)
        let latest = max(viewStart, earliest, stripEnd + gap - areas.viewSpan)
        return areas.nearestViewStartShowingEdgePeeks(
            viewStart,
            spans: spans,
            gap: gap,
            within: earliest ... latest
        ) ?? viewStart
    }
}

extension ViewportState {
    func edgePeekLanding(
        _ landing: NiriGestureMomentumPlan.Landing,
        _ columns: [NiriContainer],
        geometry: NiriViewportGeometry
    ) -> NiriGestureMomentumPlan.Landing {
        let sizeKeyPath = geometry.orientation.renderedSpanKeyPath
        let activePosition = containerPosition(
            at: landing.normalizedActiveColumn,
            containers: columns,
            gap: geometry.gap,
            sizeKeyPath: sizeKeyPath
        )
        let viewStart = viewStartRestoringEdgePeeks(
            activePosition + CGFloat(landing.finalOffset),
            columns: columns,
            areas: ViewportFittingAreas(geometry: geometry),
            gap: geometry.gap,
            sizeKeyPath: sizeKeyPath
        )
        return .init(
            finalOffset: Double(viewStart - activePosition),
            normalizedActiveColumn: landing.normalizedActiveColumn
        )
    }
}

extension ViewportFittingAreas {
    func offsetShowingEdgePeeks(
        _ offset: CGFloat,
        target: ViewportColumnTarget,
        containers: [NiriContainer],
        gap: CGFloat
    ) -> CGFloat {
        guard target.mode == .normal,
              edgePeeks != nil,
              let viewStart = viewStartShowingEdgePeeks(
                  target.position + offset,
                  spans: containers.map { $0[keyPath: orientation.settledSpanKeyPath] },
                  gap: gap
              )
        else { return offset }
        return viewStart - target.position
    }
}
