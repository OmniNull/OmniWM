// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
import TOML

@MainActor
@Observable
final class ShellConfigurationCoordinator {
    private struct MetadataScope: Equatable {
        let directories: [URL]
        let root: String?

        init(_ config: ShellConfig) {
            directories = config.directories
            root = config.island?.root
        }
    }

    struct IslandCommit: Sendable {
        let instanceID: String?
        let revision: UInt64
    }

    let shellDirectory: URL
    private(set) var config = ShellConfig()
    private(set) var catalog: ShellConfigurationCatalog?
    private(set) var widgetSchemas: [String: ShellRootSettings] = [:]
    private(set) var barLayout: ShellBarLayout?

    private(set) var styles: [ShellStyle] = []
    private(set) var themes: [String] = []
    private(set) var revision: UInt64 = 0
    private(set) var sourceGeneration: UInt64 = 0
    private(set) var metadataError: String?
    private(set) var configProblems: [String] = []
    private var pendingCount = 0
    var isSaving: Bool {
        pendingCount > 0
    }

    @ObservationIgnored var writer: ShellIslandConfigWriter?
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private let catalogLoader = ShellConfigurationCatalogLoader()
    @ObservationIgnored private let sourceLoader = ShellWidgetSourceLoader()
    @ObservationIgnored private var defaultsInstalled = false
    @ObservationIgnored private var metadataScope: MetadataScope?
    @ObservationIgnored private var inputs: ShellConfigurationInputs?
    @ObservationIgnored private var previewConfigurations: [String: ShellConfig] = [:]
    @ObservationIgnored private let editorSnapshots = ShellEditorSnapshotCache()
    @ObservationIgnored private var previewGeneration: UInt64 = 0
    @ObservationIgnored private var observation: ShellDirectoryObservation?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var observationGeneration: UInt64 = 0
    @ObservationIgnored private let onDefaultsUpdated: @MainActor ([URL]) -> Void
    @ObservationIgnored var onSave: (@MainActor (ShellConfig) -> Void)?

    init(
        shellDirectory: URL,
        onDefaultsUpdated: @escaping @MainActor ([URL]) -> Void = { _ in },
        onSave: (@MainActor (ShellConfig) -> Void)? = nil
    ) {
        self.shellDirectory = shellDirectory
        self.onDefaultsUpdated = onDefaultsUpdated
        self.onSave = onSave
    }

    func adopt(_ config: ShellConfig) {
        guard self.config != config else { return }
        self.config = config
        clearProfilePreviews()
        requestRefresh()
    }

    func ensureLoaded() async throws {
        guard metadataScope == nil else { return }
        try await refresh(onlyIfNeeded: true)
    }

    func startObserving() {
        guard observation == nil else { return }
        observation = ShellDirectoryObservation(watchLinks: true) { [weak self] in self?.requestRefresh() }
        observation?.sync(
            paths: inputs?.paths ?? [shellDirectory, shellDirectory.deletingLastPathComponent()],
            recursivePaths: inputs?.recursivePaths ?? [shellDirectory]
        )
        requestRefresh()
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
        observationGeneration += 1
        observationTask?.cancel()
        observationTask = nil
        needsRefresh = false
    }

    func refresh() async throws {
        try await refresh(onlyIfNeeded: false)
    }

    private func refresh(onlyIfNeeded: Bool) async throws {
        try await ordered { [self] in
            if onlyIfNeeded, metadataScope != nil { return }
            if !defaultsInstalled {
                let backups = try await persistence().perform { ShellDefaults.sync(into: $0) }
                if !backups.isEmpty { onDefaultsUpdated(backups) }
                defaultsInstalled = true
            }
            try await reload(scanInputs: true)
        }
    }

    func previewConfig(profile: String) async throws -> ShellConfig {
        try await ensureLoaded()
        if let cached = previewConfigurations[profile] { return cached }
        guard profiles.contains(profile) else { throw CocoaError(.fileNoSuchFile) }
        let generation = previewGeneration
        let value = try await load(profile: profile)
        try Task.checkCancellation()
        guard generation == previewGeneration else { return try await previewConfig(profile: profile) }
        previewConfigurations[profile] = value
        return value
    }

    func set<Value: Encodable>(
        _ value: Value?, key: String, table: String = "workspaceBar", profile: String? = nil
    ) async throws {
        let node = try value.map { try ShellTOMLText.node($0) }
        let path = table.split(separator: ".").map(String.init) + [key]
        try await setNode(node, path: path, profile: profile)
    }

    func reset(table: String = "workspaceBar", profile: String? = nil) async throws {
        try await setNode(nil, path: table.split(separator: ".").map(String.init), profile: profile)
    }

    func setWidgetValue(
        _ value: ShellComponentValue?, widget: String, key: String, profile: String? = nil
    ) async throws {
        let profile = try await targetProfile(profile)
        try await ordered { [self] in
            let snapshot = try await load(profile: profile)
            let schema = if metadataScope == MetadataScope(snapshot) {
                widgetSchemas[widget]
            } else {
                try await catalogLoader.settings(widgets: [widget], directories: snapshot.directories)[widget]
            }
            guard let schema,
                  let option = schema.options[key], value.map(option.accepts) != false
            else { throw ShellComponentCatalog.Failure("Invalid setting \(key) for \(widget)") }
            let name = snapshot.profile
            _ = try await persistence().perform { directory in
                try ShellProfiles.setNodes(
                    [(ShellProfiles.key("widgets", of: name) + [widget, key], value?.node)],
                    in: directory
                )
            }
            try await saved()
        }
    }

    func setWidgetOptions<Value: Encodable>(
        _ value: Value?, widget: String, key: String, profile: String? = nil
    ) async throws {
        guard ShellComponentCatalog.validName(widget), ShellComponentCatalog.validName(key) else {
            throw ShellTOMLText.Failure.invalidValue(key)
        }
        try await setNode(
            try value.map { try ShellTOMLText.node($0) },
            path: ["widgets", widget, key],
            profile: profile
        )
    }

    func setWeather<Value: Encodable>(_ value: Value?) async throws {
        let node = try value.map { try ShellTOMLText.node($0) }
        _ = try await editFile(refreshMetadata: false, scansSources: false) { directory in
            try ShellProfiles.setNodes([(["weather"], node)], in: directory)
        }
    }

    @discardableResult
    func island(_ operation: ShellIslandLayout.Operation, profile: String? = nil) async throws -> String? {
        try await islandCommit(operation, profile: try await targetProfile(profile)).instanceID
    }

    func islandCommit(
        _ operation: ShellIslandLayout.Operation,
        profile: String? = nil,
        validate: @escaping @MainActor (ShellConfig) throws -> Void = { _ in }
    ) async throws -> IslandCommit {
        try await ordered { [self] in
            let snapshot = try await load(profile: profile)
            try validate(snapshot)
            guard let island = snapshot.island else {
                throw ShellComponentCatalog.Failure("This profile has no island")
            }
            let metadata: ShellConfigurationCatalog
            if metadataScope == MetadataScope(snapshot), let catalog { metadata = catalog }
            else { metadata = try await catalogLoader.load(directories: snapshot.directories, root: island.root) }
            let layout = ShellIslandLayout(profile: snapshot.profile, root: island.root, components: island.components)
            let edit = try layout.applying(
                operation, catalog: metadata.descriptors, rootOptions: metadata.settings?.options ?? [:]
            )
            if case let .components(components) = edit.change {
                guard let source = snapshot.widget(island.root) ?? ShellConfig.bundledWidget(island.root) else {
                    throw ShellComponentCatalog.Failure("The island widget is missing")
                }
                _ = try await sourceLoader.prepare(.init(
                    name: island.root, shellDirectory: shellDirectory, sourceURL: source,
                    directories: snapshot.directories, profile: snapshot.profile, components: components
                ))
            }
            guard try await load(profile: profile) == snapshot else {
                throw ShellComponentCatalog.Failure("configuration_changed")
            }
            try validate(snapshot)
            let revision = try await persistence().persist(edit.change, profile: layout.profile, root: layout.root)
            try await saved()
            return IslandCommit(instanceID: edit.instanceID, revision: revision)
        }
    }

    func editBar(profile: String? = nil, _ change: @escaping @MainActor (inout ShellBarLayout) -> Void) async throws {
        let profile = try await targetProfile(profile)
        try await ordered { [self] in
            let snapshot = try await load(profile: profile)
            var layout = try await persistence().perform {
                ShellBarLayout(config: snapshot, shellDirectory: $0)
            }
            change(&layout)
            let next = layout
            _ = try await persistence().perform { directory in
                try next.save(shellDirectory: directory)
                return true
            }
            try await saved()
        }
    }

    func resetBarLayout(profile: String? = nil) async throws {
        let profile = try await targetProfile(profile)
        try await ordered { [self] in
            _ = try await persistence().perform { directory in
                try ShellProfiles.setNodes(
                    ["leading", "center", "trailing"].map { (ShellProfiles.key($0, of: profile), nil) },
                    in: directory
                )
            }
            try await saved()
        }
    }

    func setSystemStatsEnabled(_ enabled: Bool, profile: String? = nil) async throws {
        let profile = try await explicitProfile(profile)
        _ = try await editFile(refreshMetadata: false, scansSources: false) {
            try ShellBarLayout.setSystemStatsEnabled(enabled, profile: profile, in: $0)
        }
    }

    func updateMonitor(
        _ monitor: Monitor, profile: String? = nil, change: (@MainActor (inout MonitorBarSettings) -> Void)?
    ) async throws {
        let profile = try await targetProfile(profile)
        try await ordered { [self] in
            let snapshot = try await load(profile: profile)
            var overrides = snapshot.barOverride?.monitorOverrides ?? []
            if let change {
                var value = MonitorSettingsStore.get(for: monitor, in: overrides)
                    ?? MonitorBarSettings(monitorName: monitor.name)
                change(&value)
                if value.overriddenKeys.isEmpty { MonitorSettingsStore.remove(for: monitor, from: &overrides) }
                else { MonitorSettingsStore.update(value, for: monitor, in: &overrides) }
            } else { MonitorSettingsStore.remove(for: monitor, from: &overrides) }
            let node = try overrides.isEmpty ? nil : ShellTOMLText.node(overrides)
            let name = snapshot.profile
            _ = try await persistence().perform { directory in
                try ShellProfiles.setNodes([(ShellProfiles.key("monitorBarOverrides", of: name), node)], in: directory)
            }
            try await saved()
        }
    }

    func flush() async {
        await tail?.value
        await writer?.flush()
    }

    private func setNode(_ node: TOMLNode?, path: [String], profile: String?) async throws {
        let profile = try await targetProfile(profile)
        try await ordered { [self] in
            let name = profile
            _ = try await persistence().perform { directory in
                try ShellProfiles.setNodes([([ShellConfig.profilesKey, name] + path, node)], in: directory)
            }
            try await saved()
        }
    }
}

extension ShellConfigurationCoordinator {
    func editFile(
        refreshMetadata: Bool = true,
        scansSources: Bool = true,
        _ operation: @escaping @Sendable (URL) throws -> Bool
    ) async throws -> Bool {
        try await edit(refreshMetadata: refreshMetadata, scansSources: scansSources) { directory in
            let changed = try operation(directory)
            return (changed, changed)
        }
    }

    func edit<Value: Sendable>(
        refreshMetadata: Bool = true,
        scansSources: Bool = true,
        _ operation: @escaping @Sendable (URL) throws -> (changed: Bool, value: Value)
    ) async throws -> Value {
        try await ordered { [self] in
            let result = try await persistence().perform(operation)
            if result.changed { try await saved(refreshMetadata: refreshMetadata, scanInputs: scansSources) }
            return result.value
        }
    }

    func sharedWeather() async throws -> ShellWeatherLocation? {
        try await persistence().perform { try ShellProfiles.sharedWeather(in: $0) }
    }

    func editorSnapshot(profile: String) async throws -> ShellEditorSnapshot {
        let snapshot = try await previewConfig(profile: profile)
        if snapshot == config, let barLayout, metadataScope == MetadataScope(config) {
            return .init(
                config: snapshot, layout: barLayout, schemas: widgetSchemas, themes: themes, island: catalog,
                style: style(profile)
            )
        }
        return try await editorSnapshots.snapshot(
            for: snapshot, metadata: inputs?.metadata, generation: previewGeneration,
            writer: persistence(), catalog: catalogLoader
        )
    }

    private func targetProfile(_ profile: String?) async throws -> String {
        if let profile = try await explicitProfile(profile) { return profile }
        if !config.directories.isEmpty { return config.profile }
        return try await load().profile
    }

    func explicitProfile(_ profile: String?) async throws -> String? {
        guard let profile else { return nil }
        try await ensureLoaded()
        guard profiles.contains(profile) else { throw CocoaError(.fileNoSuchFile) }
        return profile
    }

    private func load(profile: String? = nil) async throws -> ShellConfig {
        let snapshot = try await prepared(profile: profile).config
        if let profile, snapshot.profile != profile { throw ShellBarLayout.Unreadable(problem: profile) }
        return snapshot
    }

    private func prepared(profile: String? = nil) async throws -> ShellConfigurationInputs.Prepared {
        try await persistence().perform { directory in
            try ShellConfigurationInputs.load(in: directory, profile: profile)
        }
    }

    private func reload(scanInputs: Bool = false, refreshMetadata: Bool = false, didSave: Bool = false) async throws {
        let loaded = try await prepared()
        let snapshot = loaded.config
        let previousInputs = inputs
        let nextInputs = if scanInputs || inputs == nil {
            try await persistence().perform { directory in
                try ShellConfigurationInputs(directory: directory, config: snapshot)
            }
        } else {
            try await persistence().perform { _ in previousInputs?.updatingConfiguration() }
        }
        var metadata = (schemas: widgetSchemas, catalog: catalog)
        var problem: String?
        do { metadata = try await self.metadata(for: snapshot, inputs: nextInputs, refresh: refreshMetadata) }
        catch {
            metadata = ([:], nil)
            problem = error.localizedDescription
        }
        let listing = try await persistence().perform { directory in
            (
                ShellStyle.styles(in: directory), ShellProfiles.themes(of: snapshot),
                ShellBarLayout(config: snapshot, shellDirectory: directory)
            )
        }
        let configChanged = config != snapshot
        let problemsChanged = configProblems != loaded.problems
        let filesChanged = nextInputs?.files != previousInputs?.files
        if configChanged || filesChanged {
            clearProfilePreviews()
            revision += 1
        }
        if previousInputs == nil || nextInputs?.sources != previousInputs?.sources { sourceGeneration += 1 }
        config = snapshot
        configProblems = loaded.problems
        styles = listing.0
        themes = listing.1
        barLayout = listing.2
        widgetSchemas = metadata.schemas
        catalog = metadata.catalog
        metadataError = problem
        metadataScope = problem == nil ? MetadataScope(snapshot) : nil
        inputs = nextInputs
        previewConfigurations[snapshot.profile] = snapshot
        if scanInputs || filesChanged || nextInputs?.paths != previousInputs?.paths {
            observation?.sync(paths: nextInputs?.paths ?? [], recursivePaths: nextInputs?.recursivePaths ?? [])
        }
        if didSave || configChanged || problemsChanged {
            onSave?(snapshot)
            NotificationCenter.default.post(name: .shellConfigDidChange, object: nil)
        }
    }

    private func metadata(
        for snapshot: ShellConfig, inputs nextInputs: ShellConfigurationInputs?, refresh: Bool
    ) async throws -> (schemas: [String: ShellRootSettings], catalog: ShellConfigurationCatalog?) {
        let changed = refresh || metadataScope != MetadataScope(snapshot)
            || nextInputs?.metadata != inputs?.metadata
        guard changed else { return (widgetSchemas, catalog) }
        let schemas = try await catalogLoader.settings(
            widgets: nextInputs?.widgets ?? [], directories: snapshot.directories
        )
        let catalog = if let root = snapshot.island?.root {
            try await catalogLoader.load(directories: snapshot.directories, root: root)
        } else { Optional<ShellConfigurationCatalog>.none }
        return (schemas, catalog)
    }

    private func saved(refreshMetadata: Bool = false, scanInputs: Bool = false) async throws {
        try await reload(scanInputs: scanInputs, refreshMetadata: refreshMetadata, didSave: true)
    }

    private func clearProfilePreviews() {
        previewGeneration += 1
        previewConfigurations.removeAll(keepingCapacity: true)
    }

    private func requestRefresh() {
        guard observation != nil else { return }
        needsRefresh = true
        guard observationTask == nil else { return }
        let generation = observationGeneration
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == observationGeneration { observationTask = nil } }
            while generation == observationGeneration, needsRefresh, !Task.isCancelled {
                needsRefresh = false
                do { try await refresh() }
                catch {
                    let paths = ShellConfigurationInputs.recoveryPaths(shellDirectory, config: config, previous: inputs)
                    observation?.sync(paths: paths.paths, recursivePaths: paths.recursivePaths)
                    metadataError = error.localizedDescription
                }
            }
        }
    }

    private func persistence() -> ShellIslandConfigWriter {
        if let writer { return writer }
        let value = ShellIslandConfigWriter(shellDirectory: shellDirectory) { [weak self] in
            await self?.reloadAfterPersistence()
        }
        writer = value
        return value
    }

    private func reloadAfterPersistence() async {
        do { try await refresh() }
        catch { metadataError = error.localizedDescription }
    }

    private func ordered<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) async throws
        -> Value
    {
        let previous = tail
        pendingCount += 1
        let task = Task { @MainActor [self] in
            await previous?.value
            defer { pendingCount -= 1 }
            return try await operation()
        }
        tail = Task { @MainActor in _ = try? await task.value }
        return try await task.value
    }
}
