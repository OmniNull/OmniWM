// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

@MainActor @Observable
final class WorkspaceSettings {
    private nonisolated static let defaults = SettingsExport.defaults()
    @ObservationIgnored var scriptFullscreenObserver: ConfigScriptEventObservers?
    @ObservationIgnored var onChange: (() -> Void)?

    var configurations = WorkspaceSettings.defaults.workspaceConfigurations {
        didSet {
            scriptFullscreenObserver?.workspaceLayoutsChanged(previous: oldValue, defaultLayout: defaultLayoutType)
            onChange?()
        }
    }

    var defaultLayoutType = WorkspaceSettings.defaults.defaultLayoutType {
        didSet {
            scriptFullscreenObserver?.workspaceLayoutsChanged(previous: configurations, defaultLayout: oldValue)
            onChange?()
        }
    }

    var autoBackAndForth = WorkspaceSettings.defaults.workspaceAutoBackAndForth {
        didSet { onChange?() }
    }

    func configuredNames() -> [String] {
        configurations.map(\.name)
    }

    nonisolated static func insert<Row>(_ row: Row, into rows: inout [Row], name: (Row) -> String) {
        let newName = name(row)
        let index = rows.firstIndex { WorkspaceIDPolicy.sortsBefore(newName, name($0)) } ?? rows.endIndex
        rows.insert(row, at: index)
    }

    func layoutType(for workspaceName: String) -> LayoutType {
        let layout = Self.layout(for: workspaceName, in: configurations)
        return layout == .defaultLayout ? defaultLayoutType : layout
    }

    @inline(__always)
    func configScriptLayout(for workspaceName: String) -> ActiveLayoutKind {
        let fallback = _defaultLayoutType
        let layout = Self.layout(for: workspaceName, in: _configurations)
        return (layout == .defaultLayout ? fallback : layout) == .dwindle ? .dwindle : .niri
    }

    private static func layout(
        for workspaceName: String,
        in configurations: borrowing [WorkspaceConfiguration]
    ) -> LayoutType {
        let span = configurations.span
        for index in span.indices where span[index].name == workspaceName {
            return span[index].layoutType
        }
        return .defaultLayout
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
