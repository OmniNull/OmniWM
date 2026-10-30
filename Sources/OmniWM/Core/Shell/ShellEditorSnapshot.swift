// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellEditorSnapshot: Equatable, Sendable {
    let config: ShellConfig
    let layout: ShellBarLayout
    let schemas: [String: ShellRootSettings]
    let themes: [String]
    let island: ShellConfigurationCatalog?
    let islandProblem: String?
    let descriptors: [String: ShellComponentDescriptor]
    let componentTitles: [String: String]
    let style: ShellStyle

    init(
        config: ShellConfig, layout: ShellBarLayout, schemas: [String: ShellRootSettings], themes: [String],
        island: ShellConfigurationCatalog?, islandProblem: String? = nil, style: ShellStyle? = nil
    ) {
        self.config = config
        self.layout = layout
        self.schemas = schemas
        self.themes = themes
        self.island = island
        self.islandProblem = islandProblem
        self.style = style ?? ShellStyle(name: config.profile)
        descriptors = island?.descriptors ?? [:]
        componentTitles = ShellIslandTitles.titles(
            components: config.island?.components ?? [],
            descriptors: descriptors,
            strings: self.style.strings
        )
    }
}

@MainActor
final class ShellEditorSnapshotCache {
    private struct Entry {
        let generation: UInt64
        let metadata: [String: SettingsFileAccess.Fingerprint]?
        let snapshot: ShellEditorSnapshot
    }

    private var entries: [String: Entry] = [:]

    func snapshot(
        for config: ShellConfig,
        metadata: [String: SettingsFileAccess.Fingerprint]?,
        generation: UInt64,
        writer: ShellIslandConfigWriter,
        catalog: ShellConfigurationCatalogLoader
    ) async throws -> ShellEditorSnapshot {
        let previous = entries[config.profile].flatMap {
            $0.metadata == metadata && $0.snapshot.config.directories == config.directories ? $0.snapshot : nil
        }
        if let previous, previous.islandProblem == nil, previous.config == config,
           entries[config.profile]?.generation == generation
        {
            return previous
        }
        let listing = try await writer.perform { directory in
            (
                ShellBarLayout(config: config, shellDirectory: directory), ShellProfiles.themes(of: config),
                ShellStyle.load(config.profile, in: directory)
            )
        }
        let schemas = if let previous { previous.schemas } else {
            try await catalog.settings(
                widgets: listing.0.widgets.map(\.name) + config.leading + config.center + config.trailing,
                directories: config.directories
            )
        }
        let island = await islandMetadata(for: config, reusing: previous, loader: catalog)
        let snapshot = ShellEditorSnapshot(
            config: config, layout: listing.0, schemas: schemas, themes: listing.1,
            island: island.catalog, islandProblem: island.problem, style: listing.2
        )
        entries[config.profile] = Entry(generation: generation, metadata: metadata, snapshot: snapshot)
        return snapshot
    }

    private func islandMetadata(
        for config: ShellConfig, reusing previous: ShellEditorSnapshot?, loader: ShellConfigurationCatalogLoader
    ) async -> (catalog: ShellConfigurationCatalog?, problem: String?) {
        guard let root = config.island?.root else { return (nil, nil) }
        if let previous, previous.config.island?.root == root, previous.islandProblem == nil {
            return (previous.island, nil)
        }
        do { return (try await loader.load(directories: config.directories, root: root), nil) } catch {
            return (nil, error.localizedDescription)
        }
    }
}
