// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

@MainActor @Observable
final class WorkspaceSettings {
    private nonisolated static let defaults = SettingsExport.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    var configurations = WorkspaceSettings.defaults.workspaceConfigurations {
        didSet { onChange?() }
    }

    var defaultLayoutType = WorkspaceSettings.defaults.defaultLayoutType {
        didSet { onChange?() }
    }

    func configuredNames() -> [String] {
        configurations.map(\.name)
    }

    func layoutType(for workspaceName: String) -> LayoutType {
        if let config = configurations.first(where: { $0.name == workspaceName }) {
            if config.layoutType == .defaultLayout {
                return defaultLayoutType
            }
            return config.layoutType
        }
        return defaultLayoutType
    }

    func isAccordion(for workspaceName: String) -> Bool {
        configurations.first { $0.name == workspaceName }?.accordion ?? false
    }

    func displayName(for workspaceName: String) -> String {
        configurations.first(where: { $0.name == workspaceName })?.effectiveDisplayName ?? workspaceName
    }

    static func normalizedConfigurations(_ configs: [WorkspaceConfiguration]) -> [WorkspaceConfiguration] {
        var seen: Set<String> = []
        let normalized = configs
            .filter { WorkspaceIDPolicy.normalizeRawID($0.name) != nil }
            .filter { seen.insert($0.name).inserted }
            .sorted { WorkspaceIDPolicy.sortsBefore($0.name, $1.name) }

        if normalized.isEmpty {
            return BuiltInSettingsDefaults.workspaceConfigurations
        }

        return normalized
    }
}
