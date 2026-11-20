// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum NiriStackPlace {
    case alone
    case top
    case middle
    case bottom
}

extension NiriLayoutEngine {
    func stackPlace(
        of window: NiriWindow,
        frame: CGRect,
        in column: NiriContainer,
        workspaceId: WorkspaceDescriptor.ID,
        orientation: Monitor.Orientation
    ) -> NiriStackPlace {
        let others = projectedWindows(in: column, workspaceId: workspaceId)
            .filter { $0 !== window }
            .compactMap { $0.renderedFrame ?? $0.frame }
        if others.isEmpty { return .alone }
        if others
            .allSatisfy({ orientation == .horizontal ? $0.maxY < frame.maxY : $0.maxX < frame.maxX }) { return .top }
        if others
            .allSatisfy({ orientation == .horizontal ? $0.minY > frame.minY : $0.minX > frame.minX }) { return .bottom }
        return .middle
    }
}
