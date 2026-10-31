// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct TabRailDrag {
    let info: TabRailInfo
    let visualIndex: Int
    let token: WindowToken?
    let location: CGPoint
    let pressLocation: CGPoint
}

struct TabRailDragGesture {
    struct Event: Equatable {
        let visualIndex: Int
        let pressPoint: CGPoint
    }

    private var pressedIndex: Int?
    private var pressPoint = CGPoint.zero
    let threshold: CGFloat

    init(threshold: CGFloat = MoveConfiguration.default.dragThreshold) {
        self.threshold = threshold
    }

    mutating func press(visualIndex: Int, at point: CGPoint) {
        pressedIndex = visualIndex
        pressPoint = point
    }

    mutating func drag(to point: CGPoint) -> Event? {
        guard let pressedIndex,
              hypot(point.x - pressPoint.x, point.y - pressPoint.y) >= threshold
        else { return nil }
        self.pressedIndex = nil
        return Event(visualIndex: pressedIndex, pressPoint: pressPoint)
    }

    mutating func release() {
        pressedIndex = nil
    }
}
