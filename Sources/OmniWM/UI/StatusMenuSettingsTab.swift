// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct StatusMenuSettingsTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section("Sections") {
                Toggle("Show Controls", isOn: Bindable(settings.statusMenu).showControls)
                    .id("Show Controls")
                Toggle("Show Control Help", isOn: Bindable(settings.statusMenu).showControlHelp)
                    .id("Show Control Help")
                    .disabled(!settings.statusMenu.showControls)
                Toggle("Show OmniWM Items", isOn: Bindable(settings.statusMenu).showMenuItems)
                    .id("Show OmniWM Items")
                SettingsCaption(
                    localized: "Show Controls is the master switch for the controls grid. OmniWM Items are Settings, App Rules, updates, and the Advanced, Diagnostics, and Help pages; Quit always stays available."
                )
            }
            Section("Controls") {
                ForEach(StatusMenuControl.allCases) { control in
                    Toggle(isOn: visibilityBinding(for: control)) {
                        Label(control.label, systemImage: control.icon)
                    }
                    .id("Show \(control.label)")
                    .disabled(!settings.statusMenu.showControls)
                }
                SettingsCaption(
                    localized: "Turn off a control to remove its tile from the status menu. The underlying feature keeps its current state."
                )
            }
            Section("OmniWM Items") {
                ForEach(StatusMenuItem.allCases) { item in
                    Toggle(isOn: menuItemVisibilityBinding(for: item)) {
                        Label(item.title, systemImage: item.icon)
                    }
                    .id("Show \(item.title)")
                    .disabled(!settings.statusMenu.showMenuItems)
                }
                SettingsCaption(
                    localized: "Hide individual OmniWM items from the status menu. Turn off Show OmniWM Items to hide the whole group at once."
                )
            }
        }
        .formStyle(.grouped)
    }

    func visibilityBinding(for control: StatusMenuControl) -> Binding<Bool> {
        Binding(
            get: { !settings.statusMenu.hiddenControls.contains(control.rawValue) },
            set: { settings.statusMenu.setControl(control.rawValue, isVisible: $0) }
        )
    }

    func menuItemVisibilityBinding(for item: StatusMenuItem) -> Binding<Bool> {
        Binding(
            get: { !settings.statusMenu.hiddenMenuItems.contains(item.rawValue) },
            set: { settings.statusMenu.setMenuItem(item, isVisible: $0) }
        )
    }
}
