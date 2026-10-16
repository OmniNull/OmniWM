// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
class ShellFocusPanel: NSPanel {
    var acceptsDeclaredFocus = false
    private(set) var isResigningKey = false
    var onBlur: (() -> Void)?
    var hasOwnedChildPresentation: (() -> Bool)?

    override var canBecomeKey: Bool {
        acceptsDeclaredFocus
    }

    override var canBecomeMain: Bool {
        false
    }

    override func resignKey() {
        isResigningKey = true
        super.resignKey()
        onBlur?()
        isResigningKey = false
    }
}
