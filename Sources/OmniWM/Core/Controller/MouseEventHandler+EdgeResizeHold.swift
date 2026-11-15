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
              edges.contains(.left) || edges.contains(.right),
              let frame = candidate.hit.window.renderedFrame ?? candidate.hit.window.frame,
              let column = candidate.engine.findColumn(containing: candidate.hit.window, in: candidate.workspaceId),
              let context = liveColumnContext(for: candidate.workspaceId)
        else { return }
        let room = Self.edgeResizeRoom(
            of: frame,
            in: candidate.engine.edgePeekBounds(of: column, context: context),
            screenBounds: (context.workingFrame.minX + context.gaps) ... (context.workingFrame.maxX - context.gaps)
        )
        guard let hold = Self.edgeResizeHold(
            at: location,
            edges: edges,
            centred: modifiers.contains(.maskAlternate),
            leftRoom: room.left,
            rightRoom: room.right
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
        screenBounds: ClosedRange<CGFloat>
    ) -> (left: CGFloat?, right: CGFloat?) {
        let pixel: CGFloat = 0.5
        let rightRoom = bounds.upperBound < screenBounds.upperBound - pixel
            ? max(0, bounds.upperBound - frame.maxX) : nil
        let leftRoom = bounds.lowerBound > screenBounds.lowerBound + pixel
            ? max(0, frame.minX - bounds.lowerBound) : nil
        return (leftRoom, rightRoom)
    }

    nonisolated static func edgeResizeHold(
        at location: CGPoint,
        edges: ResizeEdge,
        centred: Bool,
        leftRoom: CGFloat?,
        rightRoom: CGFloat?
    ) -> PointerEdgeBarrier.ResizeHold? {
        var hold = PointerEdgeBarrier.ResizeHold()
        if edges.contains(.right) {
            let room = centred ? [rightRoom, leftRoom].compactMap(\.self).min() : rightRoom
            hold.maxX = room.map { location.x + $0 }
        } else if edges.contains(.left) {
            let room = centred ? [leftRoom, rightRoom].compactMap(\.self).min() : leftRoom
            hold.minX = room.map { location.x - $0 }
        }
        return hold.minX == nil && hold.maxX == nil ? nil : hold
    }
}
