// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

struct StripGlide: Equatable {
    let frame: CGRect
    let since: TimeInterval
}

extension NiriLayoutEngine {
    func noteStripGlide(for token: WindowToken, from frame: CGRect, at time: TimeInterval = CACurrentMediaTime()) {
        stripGlides[token] = .init(frame: frame, since: time)
    }

    func glideIntoStrip(
        _ tokens: [WindowToken],
        context: NiriInteractionContext,
        state: ViewportState,
        at time: TimeInterval = CACurrentMediaTime()
    ) {
        stripGlides = stripGlides.filter { time - $0.value.since < 2 }
        for token in tokens {
            guard let glide = stripGlides.removeValue(forKey: token),
                  let window = findNode(for: token, in: context.workspaceId),
                  let column = findColumn(containing: window, in: context.workspaceId),
                  let landed = liveWindowFrame(of: window, in: column, context: context, state: state)
            else { continue }
            animateLiveWindow(window, from: glide.frame, to: landed, context: context)
        }
    }
}
