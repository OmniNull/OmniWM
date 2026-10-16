// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct ShellComponentGallery: View {
    let configuration: ShellConfigurationCoordinator
    let add: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Island Widget").font(.title2.bold())
            TextField("Search widgets", text: $query).textFieldStyle(.roundedBorder)
            List {
                ForEach((configuration.catalog?.entries ?? []).filter {
                    query.isEmpty || ($0.descriptor?.title ?? $0.widget).localizedStandardContains(query)
                }, id: \.widget) { entry in
                    HStack {
                        Label(
                            entry.descriptor?.title ?? ShellBarLayout.title(of: entry.widget),
                            systemImage: entry.descriptor?.icon ?? "exclamationmark.triangle"
                        )
                        Spacer()
                        Button("Add") { add(entry.widget) }.disabled(entry.descriptor == nil)
                    }
                    if let error = entry.error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .frame(minHeight: 240)
            HStack { Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 560, minHeight: 400)
    }
}

struct ShellIslandComponentInspector: View {
    let configuration: ShellConfigurationCoordinator
    let componentID: String
    @Environment(\.dismiss) private var dismiss
    @State private var editError: String?

    private var component: ShellComponentInstance? {
        configuration.config.island?.components.first { $0.id == componentID }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let component {
                    let descriptor = configuration.catalog?.descriptors[component.widget]
                    Section {
                        Label(
                            descriptor?.title ?? ShellBarLayout.title(of: component.widget),
                            systemImage: descriptor?.icon ?? "puzzlepiece.extension"
                        )
                        .font(.title2.bold())
                        Toggle("Enabled", isOn: Binding(get: { component.enabled }, set: { enabled in
                            perform { _ = try await configuration.island(.enable(id: componentID, value: enabled)) }
                        }))
                        if let root = configuration.config.island?.root,
                           configuration.catalog?.settings?.options["regions"] != nil
                        {
                            let values = ShellWidgetSettingsModel.values(widget: root, config: configuration.config)
                            Picker("Placement", selection: Binding(
                                get: { ShellWidgetSettingsModel.region(id: componentID, values: values) },
                                set: { placement in
                                    let regions = ShellWidgetSettingsModel.regions(
                                        id: componentID,
                                        placement: placement,
                                        components: configuration.config.island?.components ?? [],
                                        values: values
                                    )
                                    perform { _ = try await configuration.island(.rootSetting(
                                        key: "regions",
                                        value: regions
                                    )) }
                                }
                            )) {
                                ForEach(["auto", "main", "side", "expanded"], id: \.self) {
                                    Text(ShellWidgetSettingsModel.title($0)).tag($0)
                                }
                            }
                        }
                    }
                    Section("Options") {
                        ForEach((descriptor?.options.keys.sorted() ?? []), id: \.self) { key in
                            if let option = descriptor?.options[key] {
                                ShellSettingsOptionRow(
                                    key: key,
                                    option: option,
                                    value: component.options[key]
                                ) { value in
                                    perform { _ = try await configuration.island(.set(
                                        id: componentID,
                                        key: key,
                                        value: value
                                    )) }
                                }
                            }
                        }
                        if descriptor?.options.isEmpty != false {
                            Text("No additional options.").foregroundStyle(.secondary)
                        }
                    }
                    if component.widget == "weather" || component.widget == "calendar" {
                        ShellWeatherSettingsSection(configuration: configuration)
                    }
                } else {
                    ContentUnavailableView("Widget Removed", systemImage: "puzzlepiece.extension")
                }
            }
            .formStyle(.grouped)
            HStack { Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 500, idealWidth: 600, minHeight: 400)
        .shellSettingsError($editError)
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { editError = error.localizedDescription } }
    }
}
