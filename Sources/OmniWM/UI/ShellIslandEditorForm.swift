// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct ShellIslandEditorForm: View {
    let editor: ShellDesktopEditor
    @Environment(SettingsNavigationModel.self) private var navigation

    var body: some View {
        Form {
            ShellDesktopEditorMessages(editor: editor)
            switch editor.islandKind {
            case .composed:
                ShellIslandComponentList(editor: editor)
                if let id = editor.selectedComponent, editor.component(id) != nil {
                    ShellIslandComponentInspectorView(editor: editor, id: id)
                } else {
                    ShellIslandInspector(editor: editor)
                }
            case .focusRibbon:
                Section("Automatic Content") {
                    Label("Focus Ribbon", systemImage: "rectangle.3.group")
                    Text(
                        "Shows the focused app, workspace, and windows automatically. It expands as you switch workspaces or focus Niri windows."
                    )
                    Button("Edit Workspaces…") { navigation.request(SettingsRoute(section: .workspaces)) }
                }
                styleAppearance
                Section("Interaction") {
                    Text("Click the ribbon to expand or collapse it. Hover keeps the expanded ribbon open.")
                    SettingsCaption(localized: "The style defines its interaction and motion.")
                }
                ShellIslandPlacementInspector(editor: editor)
            case .styleDefined:
                Section("Content") {
                    Text("This island’s content is defined by its style.")
                    SettingsCaption(localized: "This style does not declare visual widget options.")
                }
                styleAppearance
                ShellIslandPlacementInspector(editor: editor)
            case let .unavailable(problem):
                Section("Island settings unavailable") {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Retry") { Task { await editor.reload() } }
                }
                ShellIslandPlacementInspector(editor: editor)
            case .absent:
                Section {
                    Label("No Island in This Style", systemImage: "capsule").font(.headline)
                    Text("This style has no Dynamic Island.")
                }
            case nil:
                if editor.problem == nil {
                    Section { ProgressView("Loading style…").frame(maxWidth: .infinity) }
                }
            }
            Section("All styles") {
                Toggle("Show Dynamic Island", isOn: Binding(
                    get: { editor.islandEnabled }, set: { editor.setIslandEnabled($0) }
                ))
                .disabled(editor.islandToggleDisabled)
                if !editor.islandEnabled, editor.island != nil {
                    SettingsCaption(
                        localized: "Configure your island before turning it on. The Workspace Bar has its own switch."
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    private var styleAppearance: some View {
        Section("Appearance") { Text("This style defines its appearance.").foregroundStyle(.secondary) }
    }
}
