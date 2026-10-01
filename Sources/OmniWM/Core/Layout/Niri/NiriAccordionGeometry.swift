// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum AccordionAxis: String, CaseIterable, Codable, Identifiable, Sendable {
    case horizontal
    case vertical

    var id: String {
        rawValue
    }
}

struct NiriAccordionInset: Equatable, Sendable {
    var leading: CGFloat
    var trailing: CGFloat

    static let zero = NiriAccordionInset(leading: 0, trailing: 0)
}

enum NiriAccordionGeometry {
    static func insets(count: Int, activeIndex: Int, padding: CGFloat, span: CGFloat) -> [NiriAccordionInset] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [.zero] }
        let maxPadding = max(0, (span - NiriAxisSolver.minimumRenderableSpan) / 2)
        let clampedPadding = min(max(0, padding), maxPadding)
        let active = activeIndex.clamped(to: 0 ... (count - 1))
        return (0 ..< count).map { index in
            switch index {
            case 0: NiriAccordionInset(leading: 0, trailing: clampedPadding)
            case count - 1: NiriAccordionInset(leading: clampedPadding, trailing: 0)
            case active - 1: NiriAccordionInset(leading: 0, trailing: 2 * clampedPadding)
            case active + 1: NiriAccordionInset(leading: 2 * clampedPadding, trailing: 0)
            default: NiriAccordionInset(leading: clampedPadding, trailing: clampedPadding)
            }
        }
    }

    static func apply(_ inset: NiriAccordionInset, to rect: CGRect, axis: AccordionAxis) -> CGRect {
        let total = inset.leading + inset.trailing
        switch axis {
        case .horizontal:
            return CGRect(
                x: rect.minX + inset.leading, y: rect.minY, width: max(0, rect.width - total), height: rect.height
            )
        case .vertical:
            return CGRect(
                x: rect.minX, y: rect.minY + inset.leading, width: rect.width, height: max(0, rect.height - total)
            )
        }
    }
}
