// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct ShellDesktopWidgetInspector: View {
    let editor: ShellDesktopEditor
    let widget: String
    @Environment(\.locale) private var locale

    private var schema: ShellRootSettings? {
        editor.schema(for: widget)
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(ShellBarLayout.title(of: widget)).font(.title3.bold())
                Text(ShellWidgetSettingsModel.description(widget)).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Source", value: source).font(.caption).foregroundStyle(.secondary)
                if let status = editor.status(for: widget) {
                    LabeledContent("Status", value: ShellWidgetSettingsModel.title(status.state, locale: locale))
                        .font(.caption)
                    if let error = status.error {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        Section {
            ForEach(schema?.options.keys.sorted() ?? [], id: \.self) { key in
                if let option = schema?.options[key] {
                    optionRow(key, option: option)
                }
            }
            if schema?.options.isEmpty != false {
                Text("This widget has no additional visual options.").foregroundStyle(.secondary)
            } else {
                Button("Reset Options to Style Defaults") {
                    editor.reset(table: "widgets." + widget)
                }
            }
        } header: { Text("Options") }
            footer: { Text("Shared by all displays in this style.") }
        if widget == "world-clock" {
            ShellDesktopClocksDraft(editor: editor)
        }
        if ["weather", "calendar", "control-center"].contains(widget) {
            ShellDesktopWeatherDraft(editor: editor)
        }
        Section {
            if editor.layout?.lane(of: widget) == nil {
                Menu("Add to Bar") {
                    ForEach(ShellLane.allCases, id: \.self) { lane in
                        Button(ShellBarLayout.side(
                            lane, vertical: ShellBarLayout.vertical(editor.barSettings, on: editor.monitors)
                        )) { Task { await editor.add(widget, to: lane) } }
                    }
                }
            } else {
                Button("Remove from Bar", role: .destructive) { editor.remove(widget) }
            }
            if schema?.network.isEmpty == false {
                Button("Network & Permissions…") { editor.openPermissions(.bar, widget) }
            }
        }
    }

    @ViewBuilder private func optionRow(_ key: String, option: ShellComponentOption) -> some View {
        if widget == "launcher", key == "mode" {
            launcherMode(key)
        } else if option.kind == .strings || option.kind == .string && !key.lowercased().hasSuffix("color") {
            ShellDesktopTextDraft(
                editor: editor, widget: widget, option: key, title: title(option),
                multiline: option.kind == .strings, maximum: option.maxLength
            )
        } else {
            let target = editor.widgetTarget(widget, key: key)
            ShellSettingsOptionRow(
                key: key, option: option,
                value: editor.pending(target, as: ShellComponentValue.self) ?? editor.values(for: widget)[key],
                strings: editor.strings
            ) {
                editor.setWidget($0, widget: widget, key: key, continuous: option.kind == .number)
            }
        }
    }

    private func launcherMode(_ key: String) -> some View {
        Picker("Open", selection: Binding(
            get: {
                if case let .string(value)? = editor.values(for: widget)[key] { value } else { "__default" }
            },
            set: { editor.setWidget($0 == "__default" ? nil : .string($0), widget: widget, key: key) }
        )) {
            Text("Last Used Palette Mode").tag("__default")
            ForEach(CommandPaletteMode.allCases, id: \.self) {
                Text(ShellWidgetSettingsModel.title($0.rawValue)).tag($0.rawValue)
            }
        }
    }

    private var source: String {
        switch editor.layout?.source(of: widget) {
        case .builtIn: String(localized: "Built-in")
        case let .profile(name): editor.configuration.styleTitle(name)
        case .yours: String(localized: "Your shell folder")
        case nil: String(localized: "Unavailable")
        }
    }

    private func title(_ option: ShellComponentOption) -> String {
        editor.strings.title(option.title, locale: locale)
    }
}
