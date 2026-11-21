// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct MenuBarSettingsPage: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Environment(SettingsNavigationModel.self) private var navigation

    private var selection: Binding<String> {
        Binding(get: { navigation.route.tab ?? "status" }, set: { navigation.selectTab($0) })
    }

    var body: some View {
        SettingsTabs(
            selection: selection,
            tabs: [
                ("macOS Status Item", "status"),
                ("Status Menu", "statusMenu"),
                ("Hidden Bar", "hidden")
            ]
        ) { tab in
            if tab == "hidden" {
                HiddenBarSettingsTab(settings: settings, controller: controller)
            } else if tab == "statusMenu" {
                StatusMenuSettingsTab(settings: settings)
            } else {
                Form {
                    Section("Status Bar") {
                        Toggle("Show Layout", isOn: Bindable(settings.statusBar).showLayout)
                            .id("Show Layout")
                            .onChange(of: settings.statusBar.showLayout) { _, _ in
                                controller.refreshStatusBar()
                                controller.requestWorkspaceBarRefresh()
                            }
                        Toggle("Show Workspace", isOn: Bindable(settings.statusBar).showWorkspaceName)
                            .id("Show Workspace")
                            .onChange(of: settings.statusBar.showWorkspaceName) { _, _ in
                                controller.refreshStatusBar()
                            }
                        Toggle("Use Workspace Number", isOn: Bindable(settings.statusBar).useWorkspaceId)
                            .id("Use Workspace Number")
                            .onChange(of: settings.statusBar.useWorkspaceId) { _, _ in
                                controller.refreshStatusBar()
                            }
                            .disabled(!settings.statusBar.showWorkspaceName)
                        Toggle("Show Focused App", isOn: Bindable(settings.statusBar).showAppNames)
                            .id("Show Focused App")
                            .onChange(of: settings.statusBar.showAppNames) { _, _ in
                                controller.refreshStatusBar()
                            }
                            .disabled(!settings.statusBar.showWorkspaceName)
                        Toggle("Show Menu Bar Icon", isOn: Bindable(settings.statusBar).showIcon)
                            .id("Show Menu Bar Icon")
                            .onChange(of: settings.statusBar.showIcon) { _, _ in
                                controller.refreshStatusBar()
                            }
                            .disabled(!settings.statusBar.showWorkspaceName && !settings.statusBar.showLayout)
                        SettingsCaption(
                            localized: "Controls OmniWM’s item in the macOS menu bar. Show Layout adds the active workspace’s layout to the macOS status item and OmniWM buttons on OmniShell bars. Show Workspace adds the active workspace and enables the app name and number options."
                        )
                    }
                    .id("Status Bar")
                }
                .formStyle(.grouped)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}
