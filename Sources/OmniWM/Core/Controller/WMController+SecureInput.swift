// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

extension WMController {
    var isSecureInputIndicated: Bool {
        hotkeysEnabled && secureInputMonitor.isSecureInputActive
    }

    func refreshHotkeyPresentation() {
        refreshHotkeyFailureSnapshots()
        refreshSecureInputPresentation()
    }

    func refreshSecureInputPresentation() {
        guard secureInputIndicator.setIndicated(isSecureInputIndicated) else { return }
        refreshStatusBar()
        requestWorkspaceBarRefresh()
    }

    func showSecureInputExplanation() {
        secureInputIndicator.showExplanation()
    }
}
