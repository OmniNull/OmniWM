// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class ShellDesktopAnchor {
    weak var view: NSView?
    let rect: @MainActor () -> CGRect?

    init(view: NSView, rect: @escaping @MainActor () -> CGRect?) {
        self.view = view
        self.rect = rect
    }

    func isCurrent() -> Bool {
        view != nil && rect() != nil
    }

    func resolve(in source: ShellDesktopSource) -> (NSView, CGRect)? {
        guard source.isCurrent(), let view, view.window === source.window, let rect = rect(),
              !rect.isEmpty, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        return (view, rect)
    }
}
