// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
class ShellFocusPanel: NSPanel {
    private var temporarilyPassesMouseEvents = false
    private var ignoresMouseEventsWhenInteractive = false
    var acceptsDeclaredFocus = false
    private(set) var isResigningKey = false
    var onBlur: (() -> Void)?
    var hasOwnedChildPresentation: (() -> Bool)?

    override var ignoresMouseEvents: Bool {
        get { super.ignoresMouseEvents }
        set {
            ignoresMouseEventsWhenInteractive = newValue
            super.ignoresMouseEvents = newValue || temporarilyPassesMouseEvents
        }
    }

    override var canBecomeKey: Bool {
        acceptsDeclaredFocus
    }

    override var canBecomeMain: Bool {
        false
    }

    func setClockClickPassThrough(_ enabled: Bool) {
        temporarilyPassesMouseEvents = enabled
        super.ignoresMouseEvents = ignoresMouseEventsWhenInteractive || enabled
    }

    override func resignKey() {
        isResigningKey = true
        super.resignKey()
        onBlur?()
        isResigningKey = false
    }
}
