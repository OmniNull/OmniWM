// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension MouseEventHandler {
    func holdEdgeResizeAtThePeek(at location: CGPoint, modifiers: CGEventFlags, in strip: PressedStrip) {
        guard let controller,
              strip.hasEdgePeeks,
              let candidate = fusionDoubleClickCandidate(at: location, in: strip),
              case let .edge(edges) = candidate.hit.zone,
              candidate.orientation == .horizontal ? edges.hasHorizontal : edges.hasVertical,
              let frame = candidate.hit.window.renderedFrame ?? candidate.hit.window.frame,
              let column = candidate.engine.findColumn(containing: candidate.hit.window, in: candidate.workspaceId),
              let context = liveColumnContext(for: candidate.workspaceId)
        else { return }
        let room = Self.edgeResizeRoom(
            of: frame,
            in: candidate.engine.edgePeekBounds(of: column, context: context),
            screenBounds: (context.primaryOrigin + context.gaps) ... (context.primaryEnd - context.gaps),
            orientation: context.orientation
        )
        guard let hold = Self.edgeResizeHold(
            at: location,
            edges: edges,
            centred: modifiers.contains(.maskAlternate),
            room: room,
            orientation: context.orientation
        ) else { return }
        controller.holdPointerForEdgeResize(hold)
    }

    func releaseEdgeResizeHold() {
        guard let controller, controller.pointerEdgeBarrier.resizeHold != nil else { return }
        controller.holdPointerForEdgeResize(nil)
    }

    nonisolated static func edgeResizeRoom(
        of frame: CGRect,
        in bounds: ClosedRange<CGFloat>,
        screenBounds: ClosedRange<CGFloat>,
        orientation: Monitor.Orientation = .horizontal
    ) -> (leading: CGFloat?, trailing: CGFloat?) {
        let horizontal = orientation == .horizontal
        let pixel: CGFloat = 0.5
        let trailing = bounds.upperBound < screenBounds.upperBound - pixel
            ? max(0, bounds.upperBound - (horizontal ? frame.maxX : frame.maxY)) : nil
        let leading = bounds.lowerBound > screenBounds.lowerBound + pixel
            ? max(0, (horizontal ? frame.minX : frame.minY) - bounds.lowerBound) : nil
        return (leading, trailing)
    }

    nonisolated static func edgeResizeHold(
        at location: CGPoint,
        edges: ResizeEdge,
        centred: Bool,
        room: (leading: CGFloat?, trailing: CGFloat?),
        orientation: Monitor.Orientation = .horizontal
    ) -> PointerEdgeBarrier.ResizeHold? {
        let horizontal = orientation == .horizontal
        let trailing = edges.contains(horizontal ? .right : .top)
        guard trailing || edges.contains(horizontal ? .left : .bottom) else { return nil }
        let available = centred
            ? room.leading.map { min($0, room.trailing ?? .infinity) } ?? room.trailing
            : trailing ? room.trailing : room.leading
        guard let available else { return nil }
        let delta = trailing ? available : -available
        let limit = horizontal ? location.x + delta : ScreenCoordinateSpace.toWindowServer(
            point: CGPoint(x: location.x, y: location.y + delta)
        ).y
        let upper = horizontal ? trailing : !trailing
        return PointerEdgeBarrier.ResizeHold(
            orientation: orientation,
            minimum: upper ? nil : limit,
            maximum: upper ? limit : nil
        )
    }
}
