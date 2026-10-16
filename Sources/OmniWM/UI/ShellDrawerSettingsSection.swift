// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct ShellDrawerSettingsSection: View {
    private struct NewDrawer: Encodable {
        let edge: String
        let widgets: [String]
    }

    let configuration: ShellConfigurationCoordinator
    let widgets: [String]
    let settings: SettingsStore
    @Environment(SettingsNavigationModel.self) private var navigation
    @State private var adding = false
    @State private var name = ""
    @State private var edge = "right"
    @State private var firstWidget = ""
    @State private var editError: String?

    var body: some View {
        Section("Drawers") {
            SettingsCaption(
                localized: "Group widgets in a panel at a screen edge. Drawers can open on hover or with a shortcut."
            )
            Button("Add Drawer…", systemImage: "plus") {
                firstWidget = widgets.first ?? ""
                adding = true
            }
            .disabled(widgets.isEmpty)
            ForEach(configuration.config.drawers, id: \.id) { drawer in
                DisclosureGroup(ShellBarLayout.title(of: drawer.id)) {
                    Picker("Screen Edge", selection: Binding(get: { drawer.edge.rawValue }, set: { value in
                        set(value, key: "edge", drawer: drawer.id)
                    })) {
                        ForEach(["left", "right", "top", "bottom"], id: \.self) {
                            Text(ShellWidgetSettingsModel.title($0)).tag($0)
                        }
                    }
                    Toggle(
                        "Open on Hover",
                        isOn: Binding(get: { drawer.hover }, set: { set($0, key: "hover", drawer: drawer.id) })
                    )
                    Toggle("Close When Pointer Leaves", isOn: Binding(get: { drawer.closesOnLeave }, set: {
                        set($0 ? "leave" : "outside", key: "close", drawer: drawer.id)
                    }))
                    Toggle(
                        "Show Panel Background",
                        isOn: Binding(get: { drawer.chrome }, set: { set($0, key: "chrome", drawer: drawer.id) })
                    )
                    SettingsSliderRow(
                        label: String(localized: "Edge Activation Area"),
                        value: Binding(
                            get: { Double(drawer.reach) },
                            set: { set($0, key: "reach", drawer: drawer.id) }
                        ),
                        range: 1 ... 100,
                        step: 1,
                        valueText: String(localized: "\(Int(drawer.reach)) pt")
                    )
                    Toggle("Custom Width", isOn: Binding(get: { drawer.width != nil }, set: {
                        set($0 ? Double(drawer.width ?? 320) : nil, key: "width", drawer: drawer.id)
                    }))
                    if let width = drawer.width {
                        SettingsNumberStepperRow(
                            label: String(localized: "Width"),
                            value: Binding(get: { Double(width) }, set: {
                                if $0.isFinite, $0 >= 1 { set($0, key: "width", drawer: drawer.id) }
                            }),
                            step: 20,
                            valueText: String(localized: "\(Int(width)) pt")
                        )
                    }
                    ForEach(drawer.widgets, id: \.self) { widget in
                        HStack {
                            Text(ShellBarLayout.title(of: widget))
                            Spacer()
                            Menu("Move") {
                                Button("Move Earlier") { shift(widget, by: -1, drawer: drawer) }
                                    .disabled(drawer.widgets.first == widget)
                                Button("Move Later") { shift(widget, by: 1, drawer: drawer) }
                                    .disabled(drawer.widgets.last == widget)
                            }
                            Button("Remove", role: .destructive) {
                                set(drawer.widgets.filter { $0 != widget }, key: "widgets", drawer: drawer.id)
                            }
                            .disabled(drawer.widgets.count <= 1)
                        }
                    }
                    Menu("Add Widget") {
                        ForEach(widgets.filter { !drawer.widgets.contains($0) }, id: \.self) { widget in
                            Button(ShellBarLayout.title(of: widget)) { set(
                                drawer.widgets + [widget],
                                key: "widgets",
                                drawer: drawer.id
                            ) }
                        }
                    }
                    Button("Configure Shortcut…") { navigation.request(SettingsRoute(
                        section: .hotkeys,
                        itemID: ActionCatalog.shellTogglePrefix + drawer.id
                    )) }
                    .disabled(!settings.hotkeyBindings
                        .contains { $0.id == ActionCatalog.shellTogglePrefix + drawer.id })
                    if !settings.hotkeyBindings
                        .contains(where: { $0.id == ActionCatalog.shellTogglePrefix + drawer.id })
                    {
                        SettingsCaption(
                            localized: "Enable the Workspace Bar or Dynamic Island to load this drawer and register its shortcut."
                        )
                    }
                    Button("Reset Drawer to Style Defaults") {
                        perform { try await configuration.reset(table: "drawer." + drawer.id) }
                    }
                }
            }
        }
        .id("Drawers")
        .sheet(isPresented: $adding) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add Drawer").font(.title2.bold())
                TextField("Drawer name", text: $name).textFieldStyle(.roundedBorder)
                Picker("Screen Edge", selection: $edge) {
                    ForEach(["left", "right", "top", "bottom"], id: \.self) {
                        Text(ShellWidgetSettingsModel.title($0)).tag($0)
                    }
                }
                Picker("First Widget", selection: $firstWidget) {
                    ForEach(widgets, id: \.self) { Text(ShellBarLayout.title(of: $0)).tag($0) }
                }
                HStack {
                    Button("Cancel") { adding = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Add") {
                        perform {
                            try await configuration.set(
                                NewDrawer(edge: edge, widgets: [firstWidget]),
                                key: name,
                                table: "drawer"
                            )
                            adding = false
                            name = ""
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ShellComponentCatalog.validName(name) || firstWidget.isEmpty || configuration.config
                        .drawers.contains { $0.id == name })
                }
            }
            .padding(20)
            .frame(minWidth: 420)
        }
        .shellSettingsError($editError)
    }

    private func shift(_ widget: String, by delta: Int, drawer: ShellDrawerConfig) {
        guard let index = drawer.widgets.firstIndex(of: widget),
              drawer.widgets.indices.contains(index + delta) else { return }
        var values = drawer.widgets
        values.swapAt(index, index + delta)
        set(values, key: "widgets", drawer: drawer.id)
    }

    private func set<Value: Encodable>(_ value: Value?, key: String, drawer: String) {
        perform { try await configuration.set(value, key: key, table: "drawer." + drawer) }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { editError = error.localizedDescription } }
    }
}
