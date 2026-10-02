// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct WindowSwitcherSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        Form {
            Section("Window Switcher") {
                Toggle("Enable Window Switcher", isOn: Bindable(settings.windowSwitcher).enabled)
                    .onChange(of: settings.windowSwitcher.enabled) { _, _ in
                        controller.updateWindowSwitcherSettings()
                    }
                if settings.windowSwitcher.enabled {
                    shortcutControls
                    Toggle("Show Switcher Footer", isOn: Bindable(settings.windowSwitcher).showFooter)
                }
                if settings.windowSwitcher.enabled, controller.hotkeysEnabled,
                   settings.windowSwitcher.export().shortcuts.isEnabled,
                   !controller.windowSwitcherInputAvailable
                {
                    SettingsCaption(
                        localized: "The window switcher could not capture keyboard input. Check Input Monitoring permission and restart OmniWM."
                    )
                }
            }

            Section("About") {
                Text(
                    "Hold Command or Option and press Tab to cycle windows. Shift reverses, release selects, and Escape cancels."
                )
                Text("Each shortcut opens its assigned workspace scope. Last Used Scope remembers your choice.")
                Text(
                    "The footer shows the scope button and window count. S changes scope; W closes the selected window."
                )
                Text("Previews require Screen Recording permission. Disable matching shortcuts in AltTab.")
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var shortcutControls: some View {
        shortcutPicker("Command-Tab", selection: Bindable(settings.windowSwitcher).commandTab)
            .onChange(of: settings.windowSwitcher.commandTab) { _, _ in
                controller.updateWindowSwitcherSettings()
            }
        shortcutPicker("Option-Tab", selection: Bindable(settings.windowSwitcher).optionTab)
            .onChange(of: settings.windowSwitcher.optionTab) { _, _ in
                controller.updateWindowSwitcherSettings()
            }
        if settings.windowSwitcher.commandTab == .remembered || settings.windowSwitcher.optionTab == .remembered {
            Picker("Remembered Scope", selection: Bindable(settings.windowSwitcher).scope) {
                Text("All Workspaces").tag(WindowSwitcherScope.allWorkspaces)
                Text("Active Workspace").tag(WindowSwitcherScope.activeWorkspace)
            }
        }
    }

    private func shortcutPicker(
        _ title: LocalizedStringKey,
        selection: Binding<WindowSwitcherShortcutScope>
    ) -> some View {
        Picker(title, selection: selection) {
            Text("Active Workspace").tag(WindowSwitcherShortcutScope.activeWorkspace)
            Text("All Workspaces").tag(WindowSwitcherShortcutScope.allWorkspaces)
            Text("Last Used Scope").tag(WindowSwitcherShortcutScope.remembered)
            Text("Disabled").tag(WindowSwitcherShortcutScope.disabled)
        }
    }
}
