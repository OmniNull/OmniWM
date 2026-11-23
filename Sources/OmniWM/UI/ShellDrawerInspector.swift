// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct ShellDrawerInspector: View {
    let editor: ShellDesktopEditor
    let drawer: ShellDrawerConfig
    @Environment(SettingsNavigationModel.self) private var navigation
    @State private var deleting = false

    init(editor: ShellDesktopEditor, drawer: ShellDrawerConfig, confirmingDelete: Bool = false) {
        self.editor = editor
        self.drawer = drawer
        _deleting = State(initialValue: confirmingDelete)
    }

    var body: some View {
        Group {
            if !editor.drawerEditable(drawer.id) {
                Section {
                    SettingsCaption(localized: "Rename this drawer in shell.luau to edit it here.")
                }
            }
            Group {
                Section("Placement") {
                    Picker("Screen Edge", selection: Binding(
                        get: { drawer.edge },
                        set: { editor.setDrawer(drawer.id, key: "edge", value: $0.rawValue) }
                    )) {
                        ForEach(ShellDrawerConfig.Edge.allCases, id: \.self) {
                            Text(ShellWidgetSettingsModel.title($0.rawValue)).tag($0)
                        }
                    }
                }
                hoverSection
                Section("Appearance") {
                    Toggle("Show Panel Background", isOn: Binding(
                        get: { drawer.chrome }, set: { editor.setDrawer(drawer.id, key: "chrome", value: $0) }
                    ))
                }
                ShellDrawerMemberList(editor: editor, drawer: drawer.id)
                shortcutSection
                Section {
                    if editor.isStyleDrawer(drawer.id) {
                        Button("Reset Drawer to Style Defaults") { editor.resetDrawer(drawer.id) }
                    } else {
                        Button("Delete Drawer…", role: .destructive) { deleting = true }
                    }
                }
            }
            .disabled(!editor.drawerEditable(drawer.id))
        }
        .confirmationDialog("Delete Drawer?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Drawer", role: .destructive) { Task { await editor.deleteDrawer(drawer.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete the “\(ShellBarLayout.title(of: drawer.id))” drawer? Its shortcut binding will be kept.")
        }
    }

    private var hoverSection: some View {
        Section("Hover") {
            Toggle("Open on Hover", isOn: Binding(
                get: { drawer.hover }, set: { editor.setDrawer(drawer.id, key: "hover", value: $0) }
            ))
            Toggle("Close When Pointer Leaves", isOn: Binding(
                get: { drawer.closesOnLeave },
                set: { editor.setDrawer(drawer.id, key: "close", value: $0 ? "leave" : "outside") }
            ))
            Group {
                let depth = editor.pending(editor.drawerTarget(drawer.id, key: "reach"), as: Double.self)
                    ?? Double(drawer.reach)
                SettingsSliderRow(
                    label: String(localized: "Hover Area Depth"),
                    value: Binding(get: { depth }, set: {
                        editor.setDrawer(drawer.id, key: "reach", value: $0, continuous: true)
                    }),
                    range: 1 ... 100, step: 1, valueText: String(localized: "\(Int(depth)) pt")
                )
                Toggle("Limit Hover Area Length", isOn: Binding(
                    get: { drawer.width != nil },
                    set: { editor.setDrawer(drawer.id, key: "width", value: $0 ? Double(drawer.width ?? 320) : nil) }
                ))
                if let width = drawer.width {
                    SettingsNumberStepperRow(
                        label: String(localized: "Length"),
                        value: Binding(get: { Double(width) }, set: {
                            guard $0.isFinite, $0 >= 1 else { return }
                            editor.setDrawer(drawer.id, key: "width", value: $0)
                        }),
                        step: 20, valueText: String(localized: "\(Int(width)) pt")
                    )
                }
            }
            .disabled(!drawer.hover)
        }
    }

    private var shortcutSection: some View {
        Section("Shortcut") {
            Button("Configure Shortcut…") {
                navigation.request(SettingsRoute(
                    section: .hotkeys,
                    itemID: ActionCatalog.shellTogglePrefix + drawer.id
                ))
            }
            .disabled(editor.drawerShortcut(drawer.id) != .available)
            switch editor.drawerShortcut(drawer.id) {
            case .available:
                EmptyView()
            case .previewing:
                SettingsCaption(localized: "Shortcuts register while this style is active.")
            case .spaces:
                SettingsCaption(localized: "Drawer names with spaces can't have a shortcut.")
            case .needsHost:
                SettingsCaption(
                    localized: "Enable the Workspace Bar or Dynamic Island to load this drawer and register its shortcut."
                )
            }
        }
    }
}
