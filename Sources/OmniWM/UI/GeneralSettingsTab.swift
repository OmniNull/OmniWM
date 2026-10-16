// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct GeneralSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let updateCoordinator: (any AppUpdateCoordinating)?
    @State private var loginItems = LoginItemManager()

    var body: some View {
        let startAtLogin = Binding(get: { loginItems.isEnabled }, set: { loginItems.setEnabled($0) })
        Form {
            Section("Language") {
                Picker("App Language", selection: $settings.language) {
                    Text("Follow macOS").tag(String?.none)
                    ForEach(AppLanguagePreference.availableLanguages, id: \.self) { language in
                        Text(AppLanguagePreference.nativeName(for: language)).tag(String?.some(language))
                    }
                }
                .id("App Language")
                SettingsCaption(localized: "Language changes take effect after you restart OmniWM.")
            }
            .id("Language")

            Section("Startup") {
                Toggle("Start at Login", isOn: startAtLogin)
                    .id("Start at Login")
                    .onAppear { loginItems.refresh() }
                    .onReceive(
                        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                    ) { _ in
                        loginItems.refresh()
                    }
                if loginItems.requiresApproval {
                    Button("Open Login Items Settings...") {
                        LoginItemManager.openLoginItemsSettings()
                    }
                    .id("Open Login Items Settings...")
                    SettingsCaption(
                        localized: "macOS needs your approval before OmniWM can start at login. Approve it under System Settings > General > Login Items."
                    )
                }
                if let loginItemError = loginItems.lastErrorDescription {
                    SettingsCaption(localized: "Could not update the login item: \(loginItemError)")
                }
                SettingsCaption(localized: "Launches OmniWM automatically when you log in.")
            }
            .id("Startup")

            Section("Updates") {
                Toggle("Check for Updates Automatically", isOn: $settings.updateChecksEnabled)
                    .id("Check for Updates Automatically")

                Button("Check for Updates...") {
                    updateCoordinator?.checkForUpdatesManually()
                }
                .id("Check for Updates...")
                .disabled(updateCoordinator == nil)

                SettingsCaption(
                    localized: "OmniWM checks the latest GitHub release once per day on launch. Updates stay manual and the popup includes both the GitHub page and the Homebrew command."
                )
            }
            .id("Updates")
        }
        .formStyle(.grouped)
    }
}
