// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class AppRulesWindowController {
    static let shared = AppRulesWindowController()

    func show(settings: SettingsStore, controller: WMController, draft: AppRuleDraft? = nil) {
        SettingsWindowController.shared.show(
            settings: settings,
            controller: controller,
            section: .appRules,
            appRuleDraft: draft
        )
    }
}
