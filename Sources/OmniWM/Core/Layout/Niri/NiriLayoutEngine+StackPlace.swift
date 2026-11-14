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
        workspaceId: WorkspaceDescriptor.ID
    ) -> NiriStackPlace {
        let others = projectedWindows(in: column, workspaceId: workspaceId)
            .filter { $0 !== window }
            .compactMap { $0.renderedFrame ?? $0.frame }
        if others.isEmpty { return .alone }
        if others.allSatisfy({ $0.maxY < frame.maxY }) { return .top }
        if others.allSatisfy({ $0.minY > frame.minY }) { return .bottom }
        return .middle
    }
}
