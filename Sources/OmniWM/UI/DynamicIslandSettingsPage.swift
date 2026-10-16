// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct DynamicIslandSettingsPage: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Environment(SettingsNavigationModel.self) private var navigation
    @State private var pane = "widgets"
    @State private var expandedPreview = false
    @State private var adding = false
    @State private var editingID: String?
    @State private var editError: String?

    private var configuration: ShellConfigurationCoordinator {
        controller.workspaceBarManager.shellConfiguration
    }

    private var island: ShellIslandConfig? {
        configuration.config.island
    }

    private var composed: Bool {
        island?.root != "focus-ribbon" && configuration.catalog?.settings != nil
    }

    private var rootValues: [String: ShellComponentValue] {
        island.map { ShellWidgetSettingsModel.values(widget: $0.root, config: configuration.config) } ?? [:]
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Enable Dynamic Island", isOn: Binding(
                        get: { settings.island.enabled },
                        set: { settings.island.enabled = $0
                            controller.updateWorkspaceBarSettings()
                        }
                    ))
                    .disabled(island == nil && !settings.island.enabled)
                    Spacer()
                    if let island { Text(ShellBarLayout.title(of: island.root)).foregroundStyle(.secondary) }
                }
                if !settings.island.enabled, island != nil {
                    SettingsCaption(
                        localized: "Configure your island before turning it on. The Workspace Bar has its own switch."
                    )
                }
                if island != nil {
                    HStack {
                        Text(ShellWidgetSettingsModel.title(configuration.config.profile)).foregroundStyle(.secondary)
                        Spacer()
                        Picker("Preview", selection: $expandedPreview) {
                            Text("Compact").tag(false)
                            Text("Expanded").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    ShellSettingsPreview(
                        config: configuration.config,
                        surface: .island(expanded: expandedPreview),
                        revision: configuration.revision
                    )
                    .frame(height: expandedPreview ? 200 : 120)
                } else {
                    ContentUnavailableView(
                        "No Island in This Style",
                        systemImage: "capsule",
                        description: Text(
                            "Choose System for Focus Ribbon or Lake for an island with customizable widgets."
                        )
                    )
                    Button("Choose a Style…") { navigation.request(SettingsRoute(section: .styles)) }
                }
                if let metadataError = configuration.metadataError {
                    Label(metadataError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            if island != nil {
                TabView(selection: $pane) {
                    Tab("Widgets", systemImage: "square.grid.2x2", value: "widgets") {
                        Form { widgetsSection }.formStyle(.grouped)
                    }
                    Tab("Appearance", systemImage: "paintpalette", value: "appearance") {
                        Form { rootSettings(
                            keys: ["appearance", "width", "radius", "backgroundColor", "highlightColor"],
                            title: "Appearance"
                        ) }.formStyle(.grouped)
                    }
                    Tab("Interaction", systemImage: "hand.point.up", value: "interaction") {
                        Form { interactionSettings }.formStyle(.grouped)
                    }
                    Tab("Placement", systemImage: "display", value: "placement") {
                        Form { placementSettings }.formStyle(.grouped)
                    }
                }
            } else { Spacer() }
        }
        .task {
            do { try await configuration.ensureLoaded() } catch { editError = error.localizedDescription }
            applyRoute()
        }
        .onChange(of: navigation.route) { _, _ in applyRoute() }
        .onChange(of: pane) { _, next in
            if navigation.route.section == .island, navigation.route.tab != next { navigation.selectTab(next) }
        }
        .sheet(isPresented: $adding) {
            ShellComponentGallery(configuration: configuration) { widget in
                Task {
                    do { editingID = try await configuration.island(.add(widget: widget, options: [:]))
                        adding = false
                    } catch { editError = error.localizedDescription }
                }
            }
        }
        .sheet(isPresented: Binding(get: { editingID != nil }, set: { if !$0 { editingID = nil } })) {
            if let component = island?.components.first(where: { $0.id == editingID }) {
                ShellIslandComponentInspector(configuration: configuration, componentID: component.id)
            }
        }
        .shellSettingsError($editError)
    }

    @ViewBuilder private var widgetsSection: some View {
        if composed, let island {
            Section("Your Widgets") {
                Button("Add Widget…", systemImage: "plus") { adding = true }
                if island.components.isEmpty {
                    ContentUnavailableView(
                        "Build Your Island",
                        systemImage: "square.grid.2x2",
                        description: Text("Add a widget to begin.")
                    )
                }
                ForEach(island.components, id: \.id) { component in
                    let descriptor = configuration.catalog?.descriptors[component.widget]
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(
                                descriptor?.title ?? ShellBarLayout.title(of: component.widget),
                                systemImage: descriptor?.icon ?? "puzzlepiece.extension"
                            )
                            Spacer()
                            Toggle("Enable \(descriptor?.title ?? component.widget)", isOn: Binding(
                                get: { component.enabled },
                                set: { enabled in perform { _ = try await configuration.island(.enable(
                                    id: component.id,
                                    value: enabled
                                )) } }
                            ))
                            .labelsHidden()
                        }
                        HStack {
                            Button("Options…") { editingID = component.id }
                            Menu("Move") {
                                Button("Move Earlier") { move(component.id, by: -1) }
                                    .disabled(island.components.first?.id == component.id)
                                Button("Move Later") { move(component.id, by: 1) }
                                    .disabled(island.components.last?.id == component.id)
                            }
                            Button("Remove", role: .destructive) {
                                perform { _ = try await configuration.island(.remove(id: component.id)) }
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
                SettingsCaption(
                    localized: "Order and placement are saved for this style. Each instance has its own options."
                )
            }
        } else if island?.root == "focus-ribbon" {
            Section("Automatic Content") {
                Label("Focus Ribbon", systemImage: "rectangle.3.group")
                Text(
                    "Shows the focused app, workspace, and windows automatically. It expands as you switch workspaces or focus Niri windows."
                )
                SettingsCaption(
                    localized: "Focus Ribbon uses your existing workspaces and window navigation. It does not use Lake’s component catalog."
                )
                Button("Edit Workspaces…") { navigation.request(SettingsRoute(section: .workspaces)) }
            }
        } else {
            Section("Content") {
                Text("This island’s content is defined by its style.")
                SettingsCaption(localized: "This style does not declare visual widget options.")
            }
        }
    }

    @ViewBuilder private var interactionSettings: some View {
        if composed {
            Section("Actions") {
                ForEach(["clickTarget", "rightClickTarget", "swipeTarget"], id: \.self) { key in
                    if let option = configuration.catalog?.settings?.options[key] {
                        Picker(option.title, selection: Binding(
                            get: {
                                if case let .string(value)? = rootValues[key] ?? option.defaultValue { value }
                                else { "none" }
                            },
                            set: { value in perform { _ = try await configuration.island(.rootSetting(
                                key: key,
                                value: .string(value)
                            )) } }
                        )) {
                            ForEach(
                                ["toggle", "expand", "collapse", "settings", "next", "previous", "none"],
                                id: \.self
                            ) {
                                Text(ShellWidgetSettingsModel.title($0)).tag($0)
                            }
                            ForEach(island?.components ?? [], id: \.id) { component in
                                Text((configuration.catalog?.descriptors[component.widget]?.title ?? component.widget) +
                                    " · " + component.id)
                                    .tag("component:" + component.id)
                                    .disabled(!component.enabled)
                            }
                        }
                    }
                }
            }
            rootSettings(
                keys: ["hoverPreview", "hoverDelay", "hoverGrace", "swipeDirection", "swipeSource", "swipeDistance"],
                title: "Hover and Swipe"
            )
            Section {
                DisclosureGroup("Advanced Motion") {
                    options(keys: ["springResponse", "springBounce"])
                }
            }
        } else {
            Section("Interaction") {
                Text("Click the ribbon to expand or collapse it. Hover keeps the expanded ribbon open.")
                SettingsCaption(localized: "The style defines its interaction and motion.")
            }
        }
    }

    @ViewBuilder private var placementSettings: some View {
        if let island {
            Section("Displays") {
                Picker("Show On", selection: Binding(get: { island.displays.rawValue }, set: { value in
                    perform { try await configuration.set(value, key: "displays", table: "island") }
                })) {
                    Text("All Displays").tag("all")
                    Text("Main Display").tag("main")
                    Text("Displays with a Notch").tag("notch")
                }
                Picker("Native Fullscreen", selection: Binding(get: { island.fullscreen.rawValue }, set: { value in
                    perform { try await configuration.set(value, key: "fullscreen", table: "island") }
                })) {
                    Text("Hide Island").tag("hide")
                    Text("Show Island").tag("show")
                }
            }
            Section {
                DisclosureGroup("Advanced Surface Size") {
                    envelope("Maximum Width", key: "width", value: island.width)
                    envelope("Maximum Height", key: "height", value: island.height)
                    SettingsCaption(
                        localized: "The style lays out its content inside this surface. These limits do not change the notch."
                    )
                }
            }
        }
    }

    @ViewBuilder private func rootSettings(keys: [String], title: String) -> some View {
        if composed {
            Section(title) { options(keys: keys) }
        } else {
            Section(title) { Text("This style defines its appearance.").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func options(keys: [String]) -> some View {
        ForEach(keys, id: \.self) { key in
            if let option = configuration.catalog?.settings?.options[key] {
                ShellSettingsOptionRow(key: key, option: option, value: rootValues[key]) { value in
                    perform { _ = try await configuration.island(.rootSetting(key: key, value: value)) }
                }
            }
        }
    }

    private func envelope(_ title: String, key: String, value: CGFloat) -> some View {
        SettingsNumberStepperRow(label: title, value: Binding(get: { Double(value) }, set: { next in
            guard next.isFinite, (1 ... 8192).contains(next) else { return }
            perform { try await configuration.set(next, key: key, table: "island") }
        }), step: 20, valueText: String(localized: "\(Int(value)) pt"))
    }

    private func move(_ id: String, by delta: Int) {
        guard let index = island?.components.firstIndex(where: { $0.id == id }) else { return }
        perform { _ = try await configuration.island(.move(id: id, index: index + delta + 1)) }
    }

    private func applyRoute() {
        guard navigation.route.section == .island else { return }
        if let tab = navigation.route.tab,
           ["widgets", "appearance", "interaction", "placement"].contains(tab) { pane = tab }
        if let id = navigation.route.itemID,
           island?.components.contains(where: { $0.id == id }) == true { editingID = id }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { editError = error.localizedDescription } }
    }
}
