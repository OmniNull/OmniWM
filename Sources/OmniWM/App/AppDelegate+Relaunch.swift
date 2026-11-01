// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension AppDelegate {
    /// Launching a running copy sends a reopen event rather than starting a second process.
    public func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        guard let bootstrap = AppDelegate.sharedBootstrap else { return false }
        if bootstrap.isReady, launchOverlayFinished {
            showSettings()
        } else {
            bootstrap.settingsPresentationDeferred = true
        }
        return false
    }

    func presentDeferredSettingsIfNeeded() {
        guard let bootstrap = AppDelegate.sharedBootstrap,
              bootstrap.settingsPresentationDeferred,
              bootstrap.isReady
        else { return }
        bootstrap.settingsPresentationDeferred = false
        showSettings()
    }
}
