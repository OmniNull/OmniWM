// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let presenter: HostedWindowPresenter
    private let navigation = SettingsNavigationModel()
    private let windowCornerPreferences = GlobalWindowCornerPreferences()

    init(presenter: HostedWindowPresenter = HostedWindowPresenter()) {
        self.presenter = presenter
    }

    var window: NSWindow? {
        presenter.window
    }

    func show(
        settings: SettingsStore,
        controller: WMController,
        updateCoordinator: (any AppUpdateCoordinating)? = nil,
        section: SettingsSection? = nil,
        anchor: String? = nil,
        presentMonitorSetup: Bool = false,
        appRuleDraft: AppRuleDraft? = nil,
        launcherRequest: LauncherEditorRequest? = nil
    ) {
        let updateCoordinator = updateCoordinator ?? controller.statusBarController?.settingsMenuModel?
            .updateCoordinator
        windowCornerPreferences.refresh()
        controller.workspaceBarManager.updateShellPermissions(settings, reloadingManagedPolicy: true)
        if presentMonitorSetup {
            navigation.requestMonitorSetupPresentation()
        } else if let section {
            navigation.request(SettingsRoute(section: section, anchor: anchor))
        }
        if let launcherRequest { navigation.presentLauncherEntry(launcherRequest) }
        if let appRuleDraft {
            navigation.presentRuleDraft(appRuleDraft)
        }

        if let window = presenter.window,
           controller.shellAppWindowManager.showSettingsWindow(window, shouldClose: closeGuard(for: window))
        {
            return
        }

        presenter.present(
            title: String(localized: "OmniWM Settings"),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            contentSize: NSSize(width: 1040, height: 760),
            minSize: NSSize(width: 760, height: 560),
            configure: { [weak self] window in
                window.delegate = self
                self?.navigation.closeWindow = { [weak window] in window?.close() }
            },
            onWillClose: { [weak self] in self?.navigation.ruleEditorState.isDirty = false },
            onPresented: { [weak self] window in
                guard let self else { return }
                controller.shellAppWindowManager.showSettingsWindow(window, shouldClose: closeGuard(for: window))
            },
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

    private func closeGuard(for window: NSWindow) -> () -> Bool {
        { [weak self, weak window] in
            guard let self, let window else { return true }
            return windowShouldClose(window)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if navigation.leaveGuard?(nil) == true { return false }
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
