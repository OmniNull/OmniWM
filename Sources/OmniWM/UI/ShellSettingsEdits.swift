// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

@MainActor
enum ShellSettingsEdits {
    static func apply(
        settings: SettingsStore,
        controller: WMController,
        _ change: @escaping @Sendable (URL, ShellConfig) throws -> Bool
    ) async throws {
        _ = try await controller.workspaceBarManager.shellConfiguration.editFile { directory in
            var problems: [String] = []
            guard let config = ShellConfig.load(shellDirectory: directory, problems: &problems) else {
                throw ShellBarLayout.Unreadable(problem: problems.last ?? "shell.toml")
            }
            return try change(directory, config)
        }
    }

    static func set<Value: Encodable>(
        _ value: Value?,
        key: String,
        table: String = "workspaceBar",
        settings: SettingsStore,
        controller: WMController
    ) async throws {
        try await controller.workspaceBarManager.shellConfiguration.set(value, key: key, table: table)
    }

    static func reset(
        table: String = "workspaceBar",
        settings: SettingsStore,
        controller: WMController
    ) async throws {
        try await controller.workspaceBarManager.shellConfiguration.reset(table: table)
    }

    static func updateMonitor(
        _ monitor: Monitor,
        settings: SettingsStore,
        controller: WMController,
        change: (@MainActor (inout MonitorBarSettings) -> Void)?
    ) async throws {
        try await controller.workspaceBarManager.shellConfiguration.updateMonitor(monitor, change: change)
    }

    static func setSystemStatsEnabled(_ enabled: Bool, settings: SettingsStore, controller: WMController) async throws {
        try await controller.workspaceBarManager.shellConfiguration.setSystemStatsEnabled(enabled)
    }
}

extension View {
    func shellSettingsError(
        _ error: Binding<String?>,
        title: LocalizedStringKey = "Unable to Save Shell Settings"
    ) -> some View {
        alert(title, isPresented: Binding(
            get: { error.wrappedValue != nil },
            set: { if !$0 { error.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) { error.wrappedValue = nil }
        } message: {
            Text(error.wrappedValue ?? "")
        }
    }
}
