// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

let statusMenuWidth: CGFloat = 280
let statusMenuScrollGutter: CGFloat = 12

enum StatusMenuGeometry {
    static func panelSize(contentSize: CGSize, visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: min(statusMenuWidth, max(1, visibleFrame.width - 16)),
            height: min(max(1, ceil(contentSize.height)), max(1, visibleFrame.height - 16))
        )
    }

    static func submenuFrame(
        rootFrame: CGRect,
        rowFrame: CGRect,
        size: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
        let right = rootFrame.maxX + 4
        let left = rootFrame.minX - 4 - size.width
        let x: CGFloat
        if right + size.width <= bounds.maxX {
            x = right
        } else if left >= bounds.minX {
            x = left
        } else {
            x = bounds.maxX - rootFrame.maxX >= rootFrame.minX - bounds.minX ? right : left
        }
        return CGRect(
            x: max(bounds.minX, min(x, bounds.maxX - size.width)),
            y: max(bounds.minY, min(rowFrame.maxY - size.height, bounds.maxY - size.height)),
            width: size.width,
            height: size.height
        )
    }
}
