// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Bindable var windowCornerPreferences: GlobalWindowCornerPreferences
    let updateCoordinator: (any AppUpdateCoordinating)?
    let navigation: SettingsNavigationModel
    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(
                selection: $selectedSection,
                diagnosticsIssueCount: controller.diagnosticsIssues.count
            )
        } detail: {
            SettingsDetailView(
                section: selectedSection,
                settings: settings,
                controller: controller,
                windowCornerPreferences: windowCornerPreferences,
                updateCoordinator: updateCoordinator,
                navigation: navigation
            )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
        .onAppear {
            selectedSection = navigation.section
        }
        .onChange(of: navigation.section) { _, newValue in
            selectedSection = newValue
        }
        .task {
            controller.refreshDiagnosticsIssues()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshDiagnosticsIssues()
        }
    }
}

struct GeneralSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Bindable var windowCornerPreferences: GlobalWindowCornerPreferences
    let updateCoordinator: (any AppUpdateCoordinating)?

    @State private var selectedGapMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()
    @State private var loginItems = LoginItemManager()

    var body: some View {
        let animationsEnabled = Binding(
            get: { controller.motionPolicy.userAnimationsEnabled },
            set: { controller.setAnimationsEnabled($0) }
        )
        let startAtLogin = Binding(
            get: { loginItems.isEnabled },
            set: { loginItems.setEnabled($0) }
        )

        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.localizedDisplayName).tag(mode)
                    }
                }
                .onChange(of: settings.appearanceMode) { _, _ in
                    controller.applyCurrentAppearanceMode()
                }

                SettingsCaption(localized: "Controls the appearance of menus and workspace bar")

                Toggle("Show app icons in tab rails", isOn: Binding(
                    get: { settings.tabRailAppIcons },
                    set: { controller.setTabRailAppIcons($0) }
                ))
                SettingsCaption(localized: "Replaces compact markers with app icons. Applies to Niri and Dwindle.")

                Toggle("Enable Animations", isOn: animationsEnabled)
                    .disabled(controller.motionPolicy.systemReducesMotion)
                SettingsCaption(
                    controller.motionPolicy.systemReducesMotion
                        ? String(localized: "Off while macOS Reduce Motion is on.")
                        : String(localized: "Turns OmniWM-authored animations on or off live without relaunching.")
                )

                AppWindowCornerSettings(preferences: windowCornerPreferences)
            }

            Section("Status Bar") {
                Toggle("Show Workspace", isOn: Bindable(settings.statusBar).showWorkspaceName)
                    .onChange(of: settings.statusBar.showWorkspaceName) { _, _ in
                        controller.refreshStatusBar()
                    }
                Toggle("Use Workspace Number", isOn: Bindable(settings.statusBar).useWorkspaceId)
                    .onChange(of: settings.statusBar.useWorkspaceId) { _, _ in
                        controller.refreshStatusBar()
                    }
                    .disabled(!settings.statusBar.showWorkspaceName)
                Toggle("Show Focused App", isOn: Bindable(settings.statusBar).showAppNames)
                    .onChange(of: settings.statusBar.showAppNames) { _, _ in
                        controller.refreshStatusBar()
                    }
                    .disabled(!settings.statusBar.showWorkspaceName)
                SettingsCaption(localized: "Shows the active workspace and focused app beside the menu bar icon")
            }

            Section("Startup") {
                Toggle("Start at Login", isOn: startAtLogin)
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
                    SettingsCaption(
                        localized: "macOS needs your approval before OmniWM can start at login. Approve it under System Settings > General > Login Items."
                    )
                }
                if let loginItemError = loginItems.lastErrorDescription {
                    SettingsCaption(localized: "Could not update the login item: \(loginItemError)")
                }
                SettingsCaption(localized: "Launches OmniWM automatically when you log in.")
            }

            Section("Updates") {
                Toggle("Check for Updates Automatically", isOn: $settings.updateChecksEnabled)

                Button("Check for Updates...") {
                    updateCoordinator?.checkForUpdatesManually()
                }
                .disabled(updateCoordinator == nil)

                SettingsCaption(
                    localized: "OmniWM checks the latest GitHub release once per day on launch. Updates stay manual and the popup includes both the GitHub page and the Homebrew command."
                )
            }

            MonitorScopeSection(
                selectedMonitor: $selectedGapMonitor,
                monitors: connectedMonitors,
                hasOverrides: { settings.gaps.settings(for: $0) != nil },
                reset: { monitor in
                    settings.gaps.remove(for: monitor)
                    controller.updateMonitorGapSettings()
                }
            )

            Section("Layout") {
                if let monitorId = selectedGapMonitor,
                   let monitor = connectedMonitors.first(where: { $0.id == monitorId })
                {
                    OverridableSlider(
                        label: String(localized: "Inner Gaps"),
                        value: settings.gaps.settings(for: monitor)?.innerGap,
                        globalValue: settings.gaps.size,
                        range: 0 ... 32,
                        step: 1,
                        formatter: { String(localized: "\(Int($0)) px") },
                        onChange: { value in updateGapSetting(for: monitor) { $0.innerGap = value } },
                        onReset: { updateGapSetting(for: monitor) { $0.innerGap = nil } }
                    )
                    SettingsCaption(localized: "Overrides the global inner gap for \(monitor.name).")
                } else {
                    SettingsSliderRow(
                        label: String(localized: "Inner Gaps"),
                        value: Bindable(settings.gaps).size,
                        range: 0 ... 32,
                        step: 1,
                        valueText: String(localized: "\(Int(settings.gaps.size)) px"),
                        valueWidth: 64
                    )
                    .onChange(of: settings.gaps.size) { _, newValue in
                        controller.setGapSize(newValue)
                    }
                }
            }

            Section("Outer Margins") {
                if let monitorId = selectedGapMonitor,
                   let monitor = connectedMonitors.first(where: { $0.id == monitorId })
                {
                    OverridableSlider(
                        label: String(localized: "Left"),
                        value: settings.gaps.settings(for: monitor)?.outerGapLeft,
                        globalValue: settings.gaps.outerGapLeft,
                        range: 0 ... 64,
                        step: 1,
                        formatter: { String(localized: "\(Int($0)) px") },
                        onChange: { value in updateGapSetting(for: monitor) { $0.outerGapLeft = value } },
                        onReset: { updateGapSetting(for: monitor) { $0.outerGapLeft = nil } }
                    )
                    OverridableSlider(
                        label: String(localized: "Right"),
                        value: settings.gaps.settings(for: monitor)?.outerGapRight,
                        globalValue: settings.gaps.outerGapRight,
                        range: 0 ... 64,
                        step: 1,
                        formatter: { String(localized: "\(Int($0)) px") },
                        onChange: { value in updateGapSetting(for: monitor) { $0.outerGapRight = value } },
                        onReset: { updateGapSetting(for: monitor) { $0.outerGapRight = nil } }
                    )
                    OverridableSlider(
                        label: String(localized: "Top"),
                        value: settings.gaps.settings(for: monitor)?.outerGapTop,
                        globalValue: settings.gaps.outerGapTop,
                        range: 0 ... 64,
                        step: 1,
                        formatter: { String(localized: "\(Int($0)) px") },
                        onChange: { value in updateGapSetting(for: monitor) { $0.outerGapTop = value } },
                        onReset: { updateGapSetting(for: monitor) { $0.outerGapTop = nil } }
                    )
                    OverridableSlider(
                        label: String(localized: "Bottom"),
                        value: settings.gaps.settings(for: monitor)?.outerGapBottom,
                        globalValue: settings.gaps.outerGapBottom,
                        range: 0 ... 64,
                        step: 1,
                        formatter: { String(localized: "\(Int($0)) px") },
                        onChange: { value in updateGapSetting(for: monitor) { $0.outerGapBottom = value } },
                        onReset: { updateGapSetting(for: monitor) { $0.outerGapBottom = nil } }
                    )
                    OverridableToggle(
                        label: String(localized: "Keep Outer Margins in Full Screen"),
                        value: settings.gaps.settings(for: monitor)?.fullscreenUsesOuterGaps,
                        globalValue: settings.gaps.fullscreenUsesOuterGaps,
                        onChange: { value in
                            updateGapSetting(for: monitor) { $0.fullscreenUsesOuterGaps = value }
                        },
                        onReset: { updateGapSetting(for: monitor) { $0.fullscreenUsesOuterGaps = nil } }
                    )
                    SettingsCaption(String(
                        localized: "Overrides selected global outer-margin values for \(monitor.name). \(topGapCaption(settings.gaps.settings(for: monitor)?.outerGapTop ?? settings.gaps.outerGapTop, on: monitor))"
                    ))
                    SettingsCaption(
                        localized: "Keeps these margins for OmniWM Full Screen and the Single Window ‘Full Screen’ fit. Any active Workspace Bar reservation is also kept; native macOS Full Screen is unchanged."
                    )
                } else {
                    SettingsSliderRow(
                        label: String(localized: "Left"),
                        value: Bindable(settings.gaps).outerGapLeft,
                        range: 0 ... 64,
                        step: 1,
                        valueText: String(localized: "\(Int(settings.gaps.outerGapLeft)) px"),
                        valueWidth: 64
                    )
                    .onChange(of: settings.gaps.outerGapLeft) { _, _ in syncOuterGaps() }

                    SettingsSliderRow(
                        label: String(localized: "Right"),
                        value: Bindable(settings.gaps).outerGapRight,
                        range: 0 ... 64,
                        step: 1,
                        valueText: String(localized: "\(Int(settings.gaps.outerGapRight)) px"),
                        valueWidth: 64
                    )
                    .onChange(of: settings.gaps.outerGapRight) { _, _ in syncOuterGaps() }

                    SettingsSliderRow(
                        label: String(localized: "Top"),
                        value: Bindable(settings.gaps).outerGapTop,
                        range: 0 ... 64,
                        step: 1,
                        valueText: String(localized: "\(Int(settings.gaps.outerGapTop)) px"),
                        valueWidth: 64
                    )
                    .onChange(of: settings.gaps.outerGapTop) { _, _ in syncOuterGaps() }
                    if let mainMonitor = connectedMonitors.first(where: \.isMain) {
                        SettingsCaption(topGapCaption(settings.gaps.outerGapTop, on: mainMonitor))
                    }

                    SettingsSliderRow(
                        label: String(localized: "Bottom"),
                        value: Bindable(settings.gaps).outerGapBottom,
                        range: 0 ... 64,
                        step: 1,
                        valueText: String(localized: "\(Int(settings.gaps.outerGapBottom)) px"),
                        valueWidth: 64
                    )
                    .onChange(of: settings.gaps.outerGapBottom) { _, _ in syncOuterGaps() }

                    Toggle(
                        "Keep Outer Margins in Full Screen",
                        isOn: Bindable(settings.gaps).fullscreenUsesOuterGaps
                    )
                    .onChange(of: settings.gaps.fullscreenUsesOuterGaps) { _, _ in
                        controller.updateMonitorGapSettings()
                    }

                    SettingsCaption(
                        localized: "Keeps these margins for OmniWM Full Screen and the Single Window ‘Full Screen’ fit. Any active Workspace Bar reservation is also kept; native macOS Full Screen is unchanged."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            connectedMonitors = Monitor.current()
        }
    }

    private func topGapCaption(_ top: Double, on monitor: Monitor) -> String {
        let menuBarInset = Int(max(0, monitor.frame.maxY - monitor.visibleFrame.maxY))
        let belowMenuBar = max(0, Int(top) - menuBarInset)
        return String(
            localized: "Top is measured from the screen's physical top edge: \(Int(top)) px → \(belowMenuBar) px below the menu bar on \(monitor.name)."
        )
    }

    private func syncOuterGaps() {
        controller.updateMonitorGapSettings()
    }

    private func updateGapSetting(for monitor: Monitor, _ update: (inout MonitorGapSettings) -> Void) {
        var ms = settings.gaps.settings(for: monitor) ?? MonitorGapSettings(
            monitorName: monitor.name
        )
        update(&ms)
        settings.gaps.update(ms, for: monitor)
        controller.updateMonitorGapSettings()
    }
}
