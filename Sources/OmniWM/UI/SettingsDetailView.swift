// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct SettingsDetailView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Bindable var windowCornerPreferences: GlobalWindowCornerPreferences
    let updateCoordinator: (any AppUpdateCoordinating)?
    @Bindable var navigation: SettingsNavigationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(navigation.section.displayName)
                    .font(.title2.weight(.semibold))
                Text(navigation.section.subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    contentView
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                        .onChange(of: navigation.route, initial: true) { _, route in
                            if let anchor = route.anchor { proxy.scrollTo(anchor, anchor: .top) }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(navigation.section.displayName)
    }

    @ViewBuilder
    private var contentView: some View {
        switch navigation.section {
        case .general:
            GeneralSettingsTab(settings: settings, controller: controller, updateCoordinator: updateCoordinator)
        case .appearance:
            AppearanceSettingsPage(
                settings: settings,
                controller: controller,
                windowCornerPreferences: windowCornerPreferences
            )
        case .styles:
            ShellStyleSettingsPage(settings: settings, controller: controller)
        case .bar:
            WorkspaceBarSettingsTab(settings: settings, controller: controller)
        case .island:
            DynamicIslandSettingsPage(settings: settings, controller: controller)
        case .widgets:
            WidgetsSettingsPage(settings: settings, controller: controller)
        case .menuBar:
            MenuBarSettingsPage(settings: settings, controller: controller)
        case .workspaces:
            WorkspacesSettingsTab(settings: settings, controller: controller)
        case .layouts:
            LayoutSettingsPage(settings: settings, controller: controller)
        case .monitors:
            MonitorSettingsTab(settings: settings, controller: controller, navigation: navigation)
        case .appRules:
            AppRulesView(settings: settings, controller: controller, editorState: navigation.ruleEditorState)
        case .overview:
            OverviewSettingsTab(settings: settings, controller: controller)
        case .hotkeys:
            HotkeySettingsView(settings: settings, controller: controller)
        case .mouseTrackpad:
            MouseTrackpadSettingsTab(settings: settings, controller: controller)
        case .quakeTerminal:
            QuakeTerminalSettingsTab(settings: settings, controller: controller)
        case .diagnostics:
            DiagnosticsSettingsTab(controller: controller, navigation: navigation)
        case .reportIssue:
            ReportIssueSettingsTab(controller: controller)
        case .advanced:
            AdvancedSettingsPage(settings: settings, controller: controller)
        }
    }
}
