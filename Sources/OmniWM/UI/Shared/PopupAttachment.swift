// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct PopupAttachment: Equatable {
    enum Edge: CaseIterable {
        case above, below, left, right
    }

    let anchor: CGPoint
    let edge: Edge

    init(anchor: CGPoint, edge: Edge = .below) {
        self.anchor = anchor
        self.edge = edge
    }

    init(sourceFrame: CGRect, edge: Edge, alignment: CGPoint? = nil) {
        self.edge = edge
        switch edge {
        case .above: anchor = CGPoint(x: alignment?.x ?? sourceFrame.midX, y: sourceFrame.maxY)
        case .below: anchor = CGPoint(x: alignment?.x ?? sourceFrame.midX, y: sourceFrame.minY)
        case .left: anchor = CGPoint(x: sourceFrame.minX, y: alignment?.y ?? sourceFrame.midY)
        case .right: anchor = CGPoint(x: sourceFrame.maxX, y: alignment?.y ?? sourceFrame.midY)
        }
    }

    func frame(size: CGSize, visibleFrame: CGRect) -> CGRect {
        let origin: CGPoint = switch edge {
        case .above: CGPoint(x: anchor.x - size.width / 2, y: anchor.y + 4)
        case .below: CGPoint(x: anchor.x - size.width / 2, y: anchor.y - 4 - size.height)
        case .left: CGPoint(x: anchor.x - 4 - size.width, y: anchor.y - size.height / 2)
        case .right: CGPoint(x: anchor.x + 4, y: anchor.y - size.height / 2)
        }
        var frame = CGRect(origin: origin, size: size)
        let minX = visibleFrame.minX + 8
        let maxX = visibleFrame.maxX - size.width - 8
        frame.origin.x = maxX >= minX ? min(max(frame.origin.x, minX), maxX) : minX
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY + 8), visibleFrame.maxY - size.height)
        return frame
    }
}
