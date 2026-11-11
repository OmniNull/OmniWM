// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMShellCore

extension ShellWidgetSurface {
    var hasMarquee: Bool {
        let root = layout.core.rootHandle
        return layout.core.contains(root) && (layout.core.content(of: root).marquee
            || layout.core.firstDescendant(of: root) { $0.marquee } != .none)
    }
}
