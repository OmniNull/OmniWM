// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct WindowSwitcherSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        Form {
            Section("Window Switcher") {
                Toggle("Replace Command-Tab", isOn: Bindable(settings.windowSwitcher).enabled)
                    .onChange(of: settings.windowSwitcher.enabled) { _, _ in
                        controller.updateWindowSwitcherSettings()
                    }
                Picker("Show Windows From", selection: Bindable(settings.windowSwitcher).scope) {
                    Text("All Workspaces").tag(WindowSwitcherScope.allWorkspaces)
                    Text("Active Workspace").tag(WindowSwitcherScope.activeWorkspace)
                }
                SettingsCaption(localized: "Active Workspace uses the workspace on OmniWM’s interaction monitor.")
                SettingsCaption(localized: "Hold Command and press Tab to cycle windows. Shift reverses direction. Release Command to focus the selection; Escape cancels.")
                SettingsCaption(localized: "Press W while the switcher is open to toggle workspace scope. Screen Recording permission is required for previews.")
                SettingsCaption(localized: "Disable AltTab’s Command-Tab shortcut before enabling this replacement.")
                if settings.windowSwitcher.enabled, controller.hotkeysEnabled,
                   !controller.windowSwitcherInputAvailable
                {
                    SettingsCaption(localized: "The window switcher could not capture keyboard input. Check Input Monitoring permission and restart OmniWM.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
