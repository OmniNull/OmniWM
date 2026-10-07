// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Observation

@MainActor @Observable
final class StatusBarSettings {
    private nonisolated static let defaults = SettingsExport.StatusBar.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    var showWorkspaceName = StatusBarSettings.defaults.showWorkspaceName {
        didSet { onChange?() }
    }

    var showAppNames = StatusBarSettings.defaults.showAppNames {
        didSet { onChange?() }
    }

    var useWorkspaceId = StatusBarSettings.defaults.useWorkspaceId {
        didSet { onChange?() }
    }

    var showIcon = StatusBarSettings.defaults.showIcon ?? true {
        didSet { onChange?() }
    }

    func export() -> SettingsExport.StatusBar {
        SettingsExport.StatusBar(
            showWorkspaceName: showWorkspaceName,
            showAppNames: showAppNames,
            useWorkspaceId: useWorkspaceId,
            showIcon: showIcon
        )
    }

    func apply(_ values: SettingsExport.StatusBar) {
        showWorkspaceName = values.showWorkspaceName
        showAppNames = values.showAppNames
        useWorkspaceId = values.useWorkspaceId
        showIcon = values.showIcon ?? true
    }
}
