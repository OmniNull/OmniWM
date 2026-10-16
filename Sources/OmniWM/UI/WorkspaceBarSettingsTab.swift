// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

enum WorkspaceBarSettingsPane: String, CaseIterable, Identifiable {
    case layout, appearance, behavior, apps

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .layout: String(localized: "Layout")
        case .appearance: String(localized: "Appearance")
        case .behavior: String(localized: "Behavior")
        case .apps: String(localized: "Apps")
        }
    }
}

struct WorkspaceBarSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Environment(SettingsNavigationModel.self) private var navigation
    @State private var selectedMonitor: Monitor.ID?
    @State private var monitors = Monitor.current()
    @State private var pane: WorkspaceBarSettingsPane = .layout
    @State private var editError: String?
    @State private var confirmingReset = false

    private var configuration: ShellConfigurationCoordinator {
        controller.workspaceBarManager.shellConfiguration
    }

    private var monitor: Monitor? {
        monitors.first { $0.id == selectedMonitor }
    }

    private var previewStyle: ShellBarStyle {
        ShellSettingsPreview.style(settings: settings.workspaceBar, config: configuration.config, monitor: monitor)
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle("Enable Workspace Bar", isOn: Binding(
                        get: { settings.workspaceBar.enabled }, set: { controller.setWorkspaceBarEnabled($0) }
                    ))
                    Spacer()
                    Text(ShellWidgetSettingsModel.title(configuration.config.profile)).foregroundStyle(.secondary)
                }
                if !settings.workspaceBar.enabled {
                    SettingsCaption(localized: "Set up your bar now. It appears when you turn it on.")
                }
                ShellSettingsPreview(
                    config: configuration.config,
                    style: previewStyle,
                    revision: configuration.revision
                )
                .frame(height: 120)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            TabView(selection: $pane) {
                Tab("Layout", systemImage: "rectangle.3.group", value: WorkspaceBarSettingsPane.layout) {
                    settingsForm(.layout)
                }
                Tab("Appearance", systemImage: "paintpalette", value: WorkspaceBarSettingsPane.appearance) {
                    settingsForm(.appearance)
                }
                Tab("Behavior", systemImage: "slider.horizontal.3", value: WorkspaceBarSettingsPane.behavior) {
                    settingsForm(.behavior)
                }
                Tab("Apps", systemImage: "app", value: WorkspaceBarSettingsPane.apps) { settingsForm(.apps) }
            }
        }
        .task {
            do { try await configuration.ensureLoaded() } catch { editError = error.localizedDescription }
            applyRoute()
        }
        .onChange(of: navigation.route) { _, _ in applyRoute() }
        .onChange(of: pane) { _, next in
            if navigation.route.section == .bar,
               navigation.route.tab != next.rawValue { navigation.selectTab(next.rawValue) }
        }
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification))
        { _ in
            monitors = Monitor.current()
            if !monitors.contains(where: { $0.id == selectedMonitor }) { selectedMonitor = nil }
        }
        .confirmationDialog("Reset this style’s bar settings?", isPresented: $confirmingReset) {
            Button("Reset Bar Settings", role: .destructive) {
                perform { try await configuration.reset() }
            }
        } message: {
            Text("Your widget layout, excluded apps, and icon overrides are kept.")
        }
        .shellSettingsError($editError)
    }

    private func settingsForm(_ pane: WorkspaceBarSettingsPane) -> some View {
        Form {
            if pane != .apps {
                MonitorScopeSection(
                    selectedMonitor: $selectedMonitor, monitors: monitors,
                    hasOverrides: {
                        MonitorSettingsStore.get(
                            for: $0,
                            in: settings.workspaceBar.profileOverride?.monitorOverrides ?? []
                        ) != nil
                    },
                    reset: { monitor in
                        perform { try await ShellSettingsEdits.updateMonitor(
                            monitor,
                            settings: settings,
                            controller: controller,
                            change: nil
                        ) }
                    }
                )
                if let monitor {
                    MonitorBarSettingsSection(settings: settings, controller: controller, monitor: monitor, pane: pane)
                } else {
                    GlobalBarSettingsSection(settings: settings, controller: controller, pane: pane)
                }
            }
            switch pane {
            case .layout:
                WorkspaceBarWidgetsSection(
                    configuration: configuration,
                    vertical: ShellBarLayout.vertical(settings.workspaceBar, on: monitors)
                )
            case .appearance:
                ShellBarEffectsSettingsSection(configuration: configuration)
            case .behavior:
                Section { Button("Reset Bar Settings to Style Defaults…") { confirmingReset = true } }
            case .apps:
                WorkspaceBarExcludedAppsSection(settings: settings, controller: controller)
                WorkspaceBarIconOverridesSection(settings: settings, controller: controller)
            }
        }
        .formStyle(.grouped)
    }

    private func applyRoute() {
        guard navigation.route.section == .bar else { return }
        if let tab = navigation.route.tab.flatMap(WorkspaceBarSettingsPane.init(rawValue:)) { pane = tab }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { editError = error.localizedDescription } }
    }
}
