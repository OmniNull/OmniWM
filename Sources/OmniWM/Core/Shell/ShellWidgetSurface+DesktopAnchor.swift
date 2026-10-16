// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

extension ShellWidgetSurface {
    func desktopAnchor(_ resolution: ShellDesktopAnchorResolution) -> ShellDesktopAnchor? {
        guard visible, sequence == resolution.sequence else { return nil }
        let handle = layout.core.resolve(path: resolution.path)
        guard handle != .none else { return nil }
        let anchor = ShellDesktopAnchor(view: view) { [weak self] in
            guard let self, visible, sequence == resolution.sequence, layout.core.contains(handle) else { return nil }
            var frame = CGRect(layout.core.absoluteFrame(of: handle)).intersection(view.bounds)
            var ancestor = handle
            while layout.core.contains(ancestor) {
                guard layout.core.paint(of: ancestor).opacity > 0 else { return nil }
                if layout.core.content(of: ancestor).scrolls {
                    frame = frame.intersection(CGRect(layout.core.absoluteFrame(of: ancestor)))
                }
                ancestor = layout.core.parent(of: ancestor)
            }
            return frame.isEmpty || frame.isNull ? nil : frame
        }
        return anchor.isCurrent() ? anchor : nil
    }
}
