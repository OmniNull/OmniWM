// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct ShellIslandComponentInspectorView: View {
    let editor: ShellDesktopEditor
    let id: String

    var body: some View {
        if let component = editor.component(id) {
            Section {
                Text(editor.componentTitle(id)).font(.title3.bold())
                Text(ShellWidgetSettingsModel.description(component.widget))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Enabled", isOn: Binding(
                    get: { editor.component(id)?.enabled ?? false }, set: { editor.setComponentEnabled(id, $0) }
                ))
                if editor.islandRootOptions["regions"] != nil {
                    Picker("Placement", selection: Binding(
                        get: {
                            var values = editor.islandRootValues
                            if let pending = editor.pending(
                                editor.islandRootTarget("regions"),
                                as: ShellComponentValue.self
                            ) {
                                values["regions"] = pending
                            }
                            return ShellWidgetSettingsModel.region(id: id, values: values)
                        },
                        set: { editor.setComponentRegion(id, $0) }
                    )) {
                        ForEach(["auto", "main", "side", "expanded"], id: \.self) {
                            Text(ShellWidgetSettingsModel.title($0)).tag($0)
                        }
                    }
                }
            }
            Section {
                ShellIslandOptionRows(
                    editor: editor, component: id,
                    keys: editor.componentDescriptor(id)?.options.keys.sorted() ?? []
                )
                if editor.componentDescriptor(id)?.options.isEmpty != false {
                    Text("No additional options.").foregroundStyle(.secondary)
                }
            } header: { Text("Options") }
                footer: { Text("Shared by all displays in this style.") }
            if component.widget == "weather" || component.widget == "calendar" {
                ShellDesktopWeatherDraft(editor: editor)
            }
            Section {
                Button("Remove from Island", role: .destructive) { editor.removeComponent(id) }
                let capabilities = editor.componentDescriptor(id)?.capabilities
                let network = (capabilities?.network ?? []) + (component.capabilities?.network ?? [])
                if !network.isEmpty || capabilities?.provider == true {
                    Button("Network & Permissions…") { editor.openPermissions(.component, component.widget) }
                }
            }
        }
    }
}

struct ShellIslandInspector: View {
    let editor: ShellDesktopEditor

    var body: some View {
        Section("Appearance") {
            ShellIslandOptionRows(
                editor: editor, keys: ["appearance", "width", "radius", "backgroundColor", "highlightColor"]
            )
        }
        Section("Actions") {
            ForEach(["clickTarget", "rightClickTarget", "swipeTarget"], id: \.self) { key in
                if let option = editor.islandRootOptions[key] {
                    Picker(option.title, selection: Binding(
                        get: {
                            if case let .string(value)? = editor.islandRootValues[key] ?? option.defaultValue {
                                value
                            } else { "none" }
                        },
                        set: { editor.setIslandRoot(key, value: .string($0)) }
                    )) {
                        ForEach(["toggle", "expand", "collapse", "settings", "next", "previous", "none"], id: \.self) {
                            Text(ShellWidgetSettingsModel.title($0)).tag($0)
                        }
                        ForEach(editor.islandComponents, id: \.id) { component in
                            Text(editor.componentTitle(component.id)).tag("component:" + component.id)
                                .disabled(!component.enabled)
                        }
                    }
                }
            }
        }
        Section("Hover and Swipe") {
            ShellIslandOptionRows(
                editor: editor,
                keys: ["hoverPreview", "hoverDelay", "hoverGrace", "swipeDirection", "swipeSource", "swipeDistance"]
            )
        }
        Section {
            DisclosureGroup("Advanced Motion") {
                ShellIslandOptionRows(editor: editor, keys: ["springResponse", "springBounce"])
            }
        }
        ShellIslandPlacementInspector(editor: editor)
    }
}

struct ShellIslandPlacementInspector: View {
    let editor: ShellDesktopEditor

    var body: some View {
        if let island = editor.island {
            Section("Placement") {
                Picker("Show On", selection: Binding(
                    get: { island.displays.rawValue }, set: { editor.setIslandPlacement($0, key: "displays") }
                )) {
                    Text("All Displays").tag("all")
                    Text("Main Display").tag("main")
                    Text("Displays with a Notch").tag("notch")
                }
                Picker("Native Fullscreen", selection: Binding(
                    get: { island.fullscreen.rawValue }, set: { editor.setIslandPlacement($0, key: "fullscreen") }
                )) {
                    Text("Hide Island").tag("hide")
                    Text("Show Island").tag("show")
                }
                if island.sizing == .fixed {
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
    }

    private func envelope(_ title: String, key: String, value: CGFloat) -> some View {
        SettingsNumberStepperRow(label: title, value: Binding(
            get: { Double(value) }, set: { next in
                guard next.isFinite, (1 ... 8192).contains(next) else { return }
                editor.setIslandPlacement(next, key: key)
            }
        ), step: 20, valueText: String(localized: "\(Int(value)) pt"))
    }
}

private struct ShellIslandOptionRows: View {
    let editor: ShellDesktopEditor
    var component: String?
    let keys: [String]
    @Environment(\.locale) private var locale

    var body: some View {
        ForEach(keys, id: \.self) { key in
            if let option = options[key] {
                if option.kind == .strings || option.kind == .string && !key.lowercased().hasSuffix("color") {
                    let draftKey: ShellEditorDraft.Key = component.map { .component($0, option: key) }
                        ?? .islandRoot(editor.island?.root ?? "", option: key)
                    ShellDesktopTextDraft(
                        editor: editor, widget: draftKey.widget, option: key, title: title(option),
                        multiline: option.kind == .strings, maximum: option.maxLength
                    )
                } else {
                    let target = component.map { editor.componentTarget($0, key: key) } ?? editor.islandRootTarget(key)
                    ShellSettingsOptionRow(
                        key: key, option: option,
                        value: editor.pending(target, as: ShellComponentValue.self) ?? values[key]
                    ) { value in
                        if let component {
                            editor.setComponentOption(
                                component,
                                key: key,
                                value: value,
                                continuous: option.kind == .number
                            )
                        } else {
                            editor.setIslandRoot(key, value: value, continuous: option.kind == .number)
                        }
                    }
                }
            }
        }
    }

    private var options: [String: ShellComponentOption] {
        component.flatMap { editor.componentDescriptor($0)?.options } ?? editor.islandRootOptions
    }

    private var values: [String: ShellComponentValue] {
        component.flatMap { editor.component($0)?.options } ?? editor.islandRootValues
    }

    private func title(_ option: ShellComponentOption) -> String {
        String(localized: LocalizedStringResource(
            String.LocalizationValue(option.title), table: ShellLocalizer.table,
            locale: locale, bundle: .atURL(Bundle.module.bundleURL)
        ))
    }
}
