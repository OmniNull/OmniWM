// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellDesktopEditor {
    var barOverride: WorkspaceBarProfileOverride? {
        snapshot?.config.barOverride
    }

    var layout: ShellBarLayout? {
        snapshot?.layout
    }

    var previewStyle: ShellBarStyle? {
        snapshot
            .map { ShellSettingsPreview.style(settings: settings.workspaceBar, config: $0.config, monitor: monitor) }
    }

    var previewDisplay: ShellSettingsPreview.Display? {
        guard let snapshot, let monitor else { return nil }
        return ShellSettingsPreview.display(settings: settings.workspaceBar, config: snapshot.config, monitor: monitor)
    }

    func inherited(for monitor: Monitor) -> ResolvedBarSettings {
        barSettings.resolved(for: monitor, includingProfileMonitor: false)
    }

    func monitorSettings(for monitor: Monitor) -> MonitorBarSettings {
        MonitorSettingsStore.get(for: monitor, in: barOverride?.monitorOverrides ?? [])
            ?? MonitorBarSettings(monitorName: monitor.name)
    }

    func schema(for widget: String) -> ShellRootSettings? {
        snapshot?.schemas[widget]
    }

    func values(for widget: String) -> [String: ShellComponentValue] {
        snapshot.map { ShellWidgetSettingsModel.values(widget: widget, config: $0.config) } ?? [:]
    }

    func status(for widget: String) -> (state: String, error: String?)? {
        guard scope == .active, let report = controller.workspaceBarManager.shellHost?.widgetReport,
              report.profile == selectedStyle, let entry = report.widgets.first(where: { $0.name == widget })
        else { return nil }
        return (entry.state, entry.error)
    }

    func barTarget(_ key: String, table: String = "workspaceBar") -> ShellSettingsWriteQueue.Target {
        .init(profile: selectedStyle, path: table.split(separator: ".").map(String.init) + [key])
    }

    func displayTarget(_ monitor: Monitor, key: String) -> ShellSettingsWriteQueue.Target {
        .init(profile: selectedStyle, monitor: monitor.id, path: ["monitorBarOverrides", key])
    }

    func widgetTarget(_ widget: String, key: String) -> ShellSettingsWriteQueue.Target {
        .init(profile: selectedStyle, path: ["widgets", widget, key])
    }

    func pending<Value>(_ target: ShellSettingsWriteQueue.Target, as type: Value.Type = Value.self) -> Value? {
        writes.value(for: target, as: type)
    }

    func set<Value: Encodable & Sendable>(
        _ value: Value?, key: String, table: String = "workspaceBar", continuous: Bool = false
    ) {
        let profile = selectedStyle
        let write: @MainActor (Value?) async throws -> Void = { [self] in
            try await configuration.set($0, key: key, table: table, profile: profile)
            if continuous { await reload() }
        }
        if continuous { writes.submit(value, for: barTarget(key, table: table), write: write) }
        else { perform { try await write(value) } }
    }

    func reset(table: String = "workspaceBar") {
        let profile = selectedStyle
        perform { [configuration] in try await configuration.reset(table: table, profile: profile) }
    }

    func setDisplay<Value: Sendable>(
        _ monitor: Monitor, key: String, value: Value, continuous: Bool = false,
        apply: @escaping @MainActor (inout MonitorBarSettings, Value) -> Void
    ) {
        let profile = selectedStyle
        let write: @MainActor (Value) async throws -> Void = { [self] value in
            try await configuration.updateMonitor(monitor, profile: profile) { apply(&$0, value) }
            if continuous { await reload() }
        }
        if continuous { writes.submit(value, for: displayTarget(monitor, key: key), write: write) }
        else { perform { try await write(value) } }
    }

    func resetDisplay(_ monitor: Monitor) {
        let profile = selectedStyle
        perform { [configuration] in try await configuration.updateMonitor(monitor, profile: profile, change: nil) }
    }

    func setWidget(_ value: ShellComponentValue?, widget: String, key: String, continuous: Bool = false) {
        let profile = selectedStyle
        let write: @MainActor (ShellComponentValue?) async throws -> Void = { [self] in
            try await configuration.setWidgetValue($0, widget: widget, key: key, profile: profile)
            if continuous { await reload() }
        }
        if continuous { writes.submit(value, for: widgetTarget(widget, key: key), write: write) }
        else { perform { try await write(value) } }
    }

    var shaderValues: [Double] {
        pending(barTarget("values", table: "barShader"), as: [Double].self) ?? snapshot?.config.barShader
            .map { shader in
                (0 ..< ShellBarShader.valueCount).map { Double(shader.values[$0]) }
            } ?? []
    }

    func setShaderValue(_ value: Double, at index: Int) {
        var values = shaderValues
        guard values.indices.contains(index) else { return }
        values[index] = value
        set(values, key: "values", table: "barShader", continuous: true)
    }

    func selectTheme(_ name: String) {
        let profile = selectedStyle
        perform { [configuration] in _ = try await configuration.selectTheme(name, profile: profile) }
    }

    func selectScheme(_ scheme: ShellWallpaperScheme) {
        let profile = selectedStyle
        perform { [configuration] in _ = try await configuration.selectScheme(scheme, profile: profile) }
    }

    func setSystemStats(_ enabled: Bool) {
        let profile = selectedStyle
        perform { [configuration] in try await configuration.setSystemStatsEnabled(enabled, profile: profile) }
    }

    var barEnabled: Bool {
        settings.workspaceBar.enabled
    }

    func setBarEnabled(_ enabled: Bool) {
        controller.setWorkspaceBarEnabled(enabled)
    }

    var islandEnabled: Bool {
        settings.island.enabled
    }

    func setIslandEnabled(_ enabled: Bool) {
        settings.island.enabled = enabled
        controller.updateWorkspaceBarSettings()
    }

    func dragPayload(for widget: String) -> String {
        ["omniwm-lane", dragToken, selectedStyle, widget].joined(separator: "\n")
    }

    @discardableResult
    func drop(_ payload: String, into lane: ShellLane, at index: Int) -> Bool {
        let parts = payload.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "omniwm-lane", parts[1] == dragToken, parts[2] == selectedStyle,
              let layout, layout.lane(of: parts[3]) != nil || layout.addable.contains(where: { $0.name == parts[3] })
        else { return false }
        let name = parts[3]
        let names = layout.names(in: lane)
        let target = layout.lane(of: name) == lane && (names.firstIndex(of: name) ?? index) < index ? index - 1 : index
        editLanes { $0.add(name, to: lane, at: min(max(0, target), names.count)) }
        focus(name)
        return true
    }

    @discardableResult
    func add(_ name: String, to lane: ShellLane) async -> Bool {
        let profile = selectedStyle
        let added = await run { [configuration] in
            try await configuration.editBar(profile: profile) { $0.add(name, to: lane) }
        }
        if added { focus(name) }
        return added
    }

    func remove(_ name: String) {
        editLanes { $0.remove(name) }
    }

    func move(_ name: String, to lane: ShellLane) {
        editLanes { $0.move(name, to: lane) }
    }

    func shift(_ name: String, by delta: Int) {
        editLanes { $0.shift(name, by: delta) }
    }

    func resetLayout() {
        let profile = selectedStyle
        perform { [configuration] in try await configuration.resetBarLayout(profile: profile) }
    }

    private func editLanes(_ change: @escaping @MainActor (inout ShellBarLayout) -> Void) {
        let profile = selectedStyle
        perform { [configuration] in try await configuration.editBar(profile: profile, change) }
    }

    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { await run(operation) }
    }

    @discardableResult
    func run(_ operation: @escaping @MainActor () async throws -> Void) async -> Bool {
        guard await writes.drain() else {
            problem = String(localized: "A change could not be saved. Retry or discard it first.")
            return false
        }
        do {
            try await operation()
            await reload()
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }
}
