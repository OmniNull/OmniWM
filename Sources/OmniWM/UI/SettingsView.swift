// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Bindable var windowCornerPreferences: GlobalWindowCornerPreferences
    let updateCoordinator: (any AppUpdateCoordinating)?
    @Bindable var navigation: SettingsNavigationModel
    @State private var refreshError: String?

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(navigation: navigation, diagnosticsIssueCount: controller.diagnosticsIssues.count)
                .frame(width: 220)
            Divider()
            SettingsDetailView(
                settings: settings, controller: controller,
                windowCornerPreferences: windowCornerPreferences,
                updateCoordinator: updateCoordinator, navigation: navigation
            )
        }
        .environment(navigation)
        .frame(minWidth: 760, minHeight: 560)
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(
            get: { navigation.pendingRoute != nil },
            set: { if !$0 { navigation.cancelNavigation() } }
        )) {
            Button("Discard Changes", role: .destructive) { navigation.discardAndNavigate() }
            Button("Cancel", role: .cancel) { navigation.cancelNavigation() }
        } message: {
            Text("You have unsaved changes to this app rule.")
        }
        .task {
            controller.workspaceBarManager.shellConfiguration.startObserving()
            controller.refreshDiagnosticsIssues()
        }
        .onDisappear { controller.workspaceBarManager.shellConfiguration.stopObserving() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshDiagnosticsIssues()
            guard [.styles, .bar, .island, .widgets, .menuBar, .advanced].contains(navigation.section) else { return }
            Task {
                do { try await controller.workspaceBarManager.shellConfiguration.refresh() }
                catch { refreshError = error.localizedDescription }
            }
        }
        .shellSettingsError($refreshError, title: "Unable to Refresh Shell Settings")
    }
}
