// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

@MainActor
final class LayoutRefreshFrameContext {
    private var cache: [WindowToken: CGRect?] = [:]

    func fastFrame(for token: WindowToken, axRef: AXWindowRef) -> CGRect? {
        if let cached = cache[token] {
            return cached
        }
        let frame = AXWindowService.framePreferFast(axRef)
        cache[token] = .some(frame)
        return frame
    }

    func prime(
        _ targets: [LayoutRefreshController.HideTarget],
        skipping isKnown: (WindowState) -> Bool,
        using readBounds: ([UInt32]) -> [UInt32: CGRect]
    ) {
        let windows = targets.compactMap { target -> (token: WindowToken, id: UInt32)? in
            guard target.entry.axRef != nil, !isKnown(target.entry), cache[target.entry.token] == nil,
                  let id = UInt32(exactly: target.entry.windowId)
            else { return nil }
            return (target.entry.token, id)
        }
        guard windows.count > 1 else { return }
        let bounds = readBounds(windows.map(\.id))
        for window in windows {
            guard let frame = bounds[window.id] else { continue }
            cache[window.token] = .some(ScreenCoordinateSpace.toAppKit(rect: frame))
        }
    }
}
