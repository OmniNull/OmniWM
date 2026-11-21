// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension CommandPaletteShellPresenter {
    func focusField(in window: NSWindow) {
        guard window.firstResponder !== field.textEditor else { return }
        window.makeFirstResponder(field.responder)
    }

    func restoreQueryFocusIfNeeded() {
        if let window = surface.view.window, window.isVisible, window.firstResponder === surface.view {
            focusField(in: window)
        }
    }
}
