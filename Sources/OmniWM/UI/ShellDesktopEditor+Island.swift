// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellDesktopEditor {
    enum IslandKind: Equatable {
        case absent
        case focusRibbon
        case composed
        case styleDefined
        case unavailable(String)
    }

    var island: ShellIslandConfig? {
        snapshot?.config.island
    }

    var islandKind: IslandKind? {
        guard let snapshot else { return nil }
        guard let island = snapshot.config.island else { return .absent }
        if island.root == ShellIslandConfig.focusRibbon { return .focusRibbon }
        if let problem = snapshot.islandProblem { return .unavailable(problem) }
        return snapshot.island?.settings == nil ? .styleDefined : .composed
    }

    var islandComponents: [ShellComponentInstance] {
        island?.components ?? []
    }

    var islandEntries: [ShellComponentCatalog.Entry] {
        snapshot?.island?.entries ?? []
    }

    var islandRootOptions: [String: ShellComponentOption] {
        snapshot?.island?.settings?.options ?? [:]
    }

    var islandRootValues: [String: ShellComponentValue] {
        guard let snapshot, let root = snapshot.config.island?.root else { return [:] }
        return ShellWidgetSettingsModel.values(widget: root, config: snapshot.config)
    }

    var islandFullWidth: Bool {
        barOverride?.settings.fullWidth ?? false
    }

    var islandToggleDisabled: Bool {
        island == nil && !islandEnabled
    }

    func component(_ id: String) -> ShellComponentInstance? {
        islandComponents.first { $0.id == id }
    }

    func componentTitle(_ id: String) -> String {
        snapshot?.componentTitles[id] ?? component(id).map { ShellBarLayout.title(of: $0.widget) } ?? id
    }

    func componentDescriptor(_ id: String) -> ShellComponentDescriptor? {
        component(id).flatMap { snapshot?.descriptors[$0.widget] }
    }

    func componentTarget(_ id: String, key: String) -> ShellSettingsWriteQueue.Target {
        .init(profile: selectedStyle, path: ["island", id, key])
    }

    func islandRootTarget(_ key: String) -> ShellSettingsWriteQueue.Target {
        .init(profile: selectedStyle, path: ["island-root", key])
    }

    @discardableResult
    func addComponent(_ widget: String) async -> Bool {
        let profile = selectedStyle
        return await run { [self] in
            if let id = try await configuration.island(.add(widget: widget, options: [:]), profile: profile) {
                focusComponent(id)
            }
        }
    }

    func removeComponent(_ id: String) {
        let profile = selectedStyle
        let selected = selectedComponent == id
        perform { [self] in
            _ = try await configuration.island(.remove(id: id), profile: profile)
            for key in Array(drafts.keys) where key.component == id || selected && key == .weather {
                clearDraft(key)
            }
        }
    }

    func setComponentEnabled(_ id: String, _ enabled: Bool) {
        islandOperation(.enable(id: id, value: enabled))
    }

    func moveComponent(_ id: String, to index: Int) {
        islandOperation(.move(id: id, index: index + 1))
    }

    func shiftComponent(_ id: String, by delta: Int) {
        guard let index = islandComponents.firstIndex(where: { $0.id == id }),
              islandComponents.indices.contains(index + delta)
        else { return }
        moveComponent(id, to: index + delta)
    }

    func componentDragPayload(for id: String) -> String {
        ["omniwm-island", dragToken, selectedStyle, id].joined(separator: "\n")
    }

    @discardableResult
    func dropComponent(_ payload: String, at index: Int) -> Bool {
        let parts = payload.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "omniwm-island", parts[1] == dragToken, parts[2] == selectedStyle,
              let position = islandComponents.firstIndex(where: { $0.id == parts[3] })
        else { return false }
        let target = min(max(0, position < index ? index - 1 : index), islandComponents.count - 1)
        guard target != position else { return false }
        moveComponent(parts[3], to: target)
        focusComponent(parts[3])
        return true
    }

    func setComponentRegion(_ id: String, _ region: String) {
        let regions = ShellWidgetSettingsModel.regions(
            id: id, placement: region, components: islandComponents, values: islandRootValues
        )
        islandOperation(.rootSetting(key: "regions", value: regions))
    }

    func setComponentOption(_ id: String, key: String, value: ShellComponentValue, continuous: Bool = false) {
        islandValue(value, target: componentTarget(id, key: key), continuous: continuous) {
            .set(id: id, key: key, value: $0)
        }
    }

    func setIslandRoot(_ key: String, value: ShellComponentValue, continuous: Bool = false) {
        islandValue(value, target: islandRootTarget(key), continuous: continuous) {
            .rootSetting(key: key, value: $0)
        }
    }

    func setIslandPlacement(_ value: some Encodable & Sendable, key: String) {
        let profile = selectedStyle
        perform { [configuration] in try await configuration.set(value, key: key, table: "island", profile: profile) }
    }

    private func islandOperation(_ operation: ShellIslandLayout.Operation) {
        let profile = selectedStyle
        perform { [configuration] in _ = try await configuration.island(operation, profile: profile) }
    }

    private func islandValue(
        _ value: ShellComponentValue, target: ShellSettingsWriteQueue.Target, continuous: Bool,
        operation: @escaping @MainActor (ShellComponentValue) -> ShellIslandLayout.Operation
    ) {
        let profile = selectedStyle
        let write: @MainActor (ShellComponentValue) async throws -> Void = { [self] in
            _ = try await configuration.island(operation($0), profile: profile)
            if continuous { await reload() }
        }
        if continuous { writes.submit(value, for: target, write: write) }
        else { perform { try await write(value) } }
    }
}
