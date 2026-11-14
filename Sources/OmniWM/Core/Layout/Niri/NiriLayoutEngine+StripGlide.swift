// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct StripGlide: Equatable {
    let frame: CGRect
}

extension NiriLayoutEngine {
    func noteStripGlide(for token: WindowToken, from frame: CGRect) {
        stripGlides[token] = .init(frame: frame)
    }

    func glideIntoStrip(_ tokens: [WindowToken], context: NiriInteractionContext, state: ViewportState) {
        guard !stripGlides.isEmpty else { return }
        let placedNow = Set(tokens)
        for token in stripGlides.keys
            where !placedNow.contains(token) && findNode(for: token, in: context.workspaceId) != nil
        {
            stripGlides.removeValue(forKey: token)
        }
        guard context.orientation == .horizontal else {
            for token in tokens {
                stripGlides.removeValue(forKey: token)
            }
            return
        }
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
