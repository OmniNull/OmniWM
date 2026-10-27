// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

enum NaturalDoubleClickZone: Equatable {
    case edge(ResizeEdge)
    case titleBar
}

struct NaturalDoubleClickHit {
    let window: NiriWindow
    let zone: NaturalDoubleClickZone
}

extension NiriLayoutEngine {
    static let doubleClickEdgeInset: CGFloat = 4
    static let doubleClickEdgeOutset: CGFloat = 6
    static let doubleClickTitleBarDepth: CGFloat = 52

    static func naturalDoubleClickZone(
        at point: CGPoint,
        in frame: CGRect,
        gap: CGFloat,
        bounds: CGRect
    ) -> NaturalDoubleClickZone? {
        guard bounds.contains(point) else { return nil }
        let outset = min(doubleClickEdgeOutset, max(0, gap / 2))
        let reach = frame.insetBy(dx: -outset, dy: -outset)
        guard reach.contains(point) else { return nil }

        var edges: ResizeEdge = []
        if point.x < frame.minX + doubleClickEdgeInset { edges.insert(.left) }
        if point.x >= frame.maxX - doubleClickEdgeInset { edges.insert(.right) }
        if point.y < frame.minY + doubleClickEdgeInset { edges.insert(.bottom) }
        if point.y >= frame.maxY - doubleClickEdgeInset { edges.insert(.top) }

        switch edges {
        case []:
            return point.y >= frame.maxY - doubleClickTitleBarDepth ? .titleBar : nil
        case .left,
             .right,
             .top,
             .bottom:
            return .edge(edges)
        default:
            return nil
        }
    }

    func naturalDoubleClickHit(
        at point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        gap: CGFloat,
        bounds: CGRect
    ) -> NaturalDoubleClickHit? {
        for column in projectedColumns(in: workspaceId) {
            for window in column.windows {
                guard isProjectedFocusableWindow(window, in: workspaceId),
                      !window.isFullscreen,
                      let frame = window.renderedFrame ?? window.frame,
                      let zone = Self.naturalDoubleClickZone(at: point, in: frame, gap: gap, bounds: bounds)
                else { continue }
                return NaturalDoubleClickHit(window: window, zone: zone)
            }
        }
        return nil
    }
}
