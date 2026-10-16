// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let presenter = HostedWindowPresenter()
    private let navigation = SettingsNavigationModel()
    private let windowCornerPreferences = GlobalWindowCornerPreferences()

    func show(
        settings: SettingsStore,
        controller: WMController,
        updateCoordinator: (any AppUpdateCoordinating)? = nil,
        section: SettingsSection? = nil,
        presentMonitorSetup: Bool = false,
        appRuleDraft: AppRuleDraft? = nil
    ) {
        let updateCoordinator = updateCoordinator ?? controller.statusBarController?.settingsMenuModel?
            .updateCoordinator
        windowCornerPreferences.refresh()
        if presentMonitorSetup {
            navigation.requestMonitorSetupPresentation()
        } else if let section {
            navigation.section = section
        }
        if let appRuleDraft {
            navigation.presentRuleDraft(appRuleDraft)
        }

        presenter.present(
            title: String(localized: "OmniWM Settings"),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            contentSize: NSSize(width: 1040, height: 760),
            minSize: NSSize(width: 760, height: 560),
            configure: { [weak self] window in window.delegate = self },
            onWillClose: { [weak self] in self?.navigation.ruleEditorState.isDirty = false },
            content: {
                SettingsView(
                    settings: settings,
                    controller: controller,
                    windowCornerPreferences: windowCornerPreferences,
                    updateCoordinator: updateCoordinator,
                    navigation: navigation
                )
            }
        )
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard navigation.ruleEditorState.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard unsaved changes?")
        alert
            .informativeText =
            String(localized: "You have unsaved changes to this app rule. Closing the window will discard them.")
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        navigation.ruleEditorState.isDirty = false
        return true
    }
}
