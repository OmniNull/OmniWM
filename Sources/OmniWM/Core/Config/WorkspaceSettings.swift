// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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

    var autoBackAndForth = WorkspaceSettings.defaults.workspaceAutoBackAndForth {
        didSet { onChange?() }
    }

    func configuredNames() -> [String] {
        configurations.map(\.name)
    }

    func layoutType(for workspaceName: String) -> LayoutType {
        let configurations = self.configurations
        let span = configurations.span
        for index in span.indices where span[index].name == workspaceName {
            let layoutType = span[index].layoutType
            return layoutType == .defaultLayout ? defaultLayoutType : layoutType
        }
        return defaultLayoutType
    }

    func displayName(for workspaceName: String) -> String {
        let configurations = self.configurations
        let span = configurations.span
        for index in span.indices where span[index].name == workspaceName {
            return span[index].effectiveDisplayName
        }
        return workspaceName
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
