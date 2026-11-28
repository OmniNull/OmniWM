// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellConfigurationCoordinator {
    private struct NewDrawer: Encodable {
        let edge: String
        let widgets: [String]
    }

    func addDrawer(_ name: String, edge: ShellDrawerConfig.Edge, widget: String, profile: String) async throws {
        let id = ShellDrawerName.normalized(name)
        let directory = shellDirectory
        let node = try SettingsLuauValue.encoding(NewDrawer(edge: edge.rawValue, widgets: [widget]))
        try await editDrawers(profile: profile) { config in
            let drawers = config.drawers.map(\.id) + config.styleDrawers
            let widgets = ShellDrawerName.widgets(
                ShellBarLayout(config: config, shellDirectory: directory),
                config: config
            )
            if let problem = ShellDrawerName.problem(id, drawers: drawers, widgets: widgets) {
                throw ShellComponentCatalog.Failure(problem)
            }
            return [(["drawer", id], node)]
        }
    }

    func editDrawerWidgets(
        _ id: String, profile: String, _ change: @escaping @Sendable (inout [String]) -> Void
    ) async throws {
        try await editDrawers(profile: profile) { config in
            guard var widgets = config.drawers.first(where: { $0.id == id })?.widgets else {
                throw ShellComponentCatalog.Failure(String(localized: "This drawer no longer exists."))
            }
            change(&widgets)
            guard !widgets.isEmpty else {
                throw ShellComponentCatalog.Failure(String(localized: "A drawer needs at least one widget."))
            }
            return try [(["drawer", id, "widgets"], SettingsLuauValue.encoding(widgets))]
        }
    }

    func deleteDrawer(_ id: String, profile: String) async throws {
        try await editDrawers(profile: profile) { config in
            guard !config.styleDrawers.contains(id) else {
                throw ShellComponentCatalog
                    .Failure(String(localized: "A drawer that comes with the style can only be reset."))
            }
            guard config.drawers.contains(where: { $0.id == id }) else {
                throw ShellComponentCatalog.Failure(String(localized: "This drawer no longer exists."))
            }
            return [(["drawer", id], nil)]
        }
    }

    private func editDrawers(
        profile: String, _ edit: @escaping @Sendable (ShellConfig) throws -> [([String], SettingsLuauValue?)]
    ) async throws {
        try await ensureLoaded()
        _ = try await editFile(refreshMetadata: false, scansSources: false) { directory in
            guard ShellProfiles.names(in: directory).contains(profile) else { throw CocoaError(.fileNoSuchFile) }
            let config = try ShellConfigurationInputs.load(in: directory, profile: profile).config
            guard config.profile == profile else { throw ShellBarLayout.Unreadable(problem: profile) }
            let entries = try edit(config).map { (key: [ShellConfig.profilesKey, profile] + $0.0, value: $0.1) }
            return try ShellProfiles.setNodes(entries, in: directory)
        }
    }
}
