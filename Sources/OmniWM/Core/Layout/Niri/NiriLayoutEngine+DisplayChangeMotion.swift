// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    func animateDisplayChange(
        of column: NiriContainer,
        from previousPlaces: [NodeId: CGRect],
        onlyMoving shown: NiriWindow? = nil,
        context: NiriInteractionContext
    ) {
        let places = liveWindowPlaces(in: [column], context: context)
        for window in projectedWindows(in: column, workspaceId: context.workspaceId) {
            guard let previous = previousPlaces[window.id], let current = places[window.id] else { continue }
            window.stopMoveAnimations()
            if let shown, window !== shown { continue }
            animateLiveWindow(window, from: previous, to: current, context: context)
        }
    }
}
