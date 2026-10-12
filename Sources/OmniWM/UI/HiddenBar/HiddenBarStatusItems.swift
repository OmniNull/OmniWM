// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class HiddenBarStatusItems {
    private weak var omniButton: NSStatusBarButton?

    func ownsStatusItemWindow(_ window: NSWindow) -> Bool {
        window === omniButton?.window
    }

    func bind(omniButton: NSStatusBarButton) {
        self.omniButton = omniButton
    }
}
