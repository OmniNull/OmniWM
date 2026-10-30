// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct ShellDesktopEditorPage: View {
    @State private var editor: ShellDesktopEditor
    @State private var expandedPreview = false
    @Environment(SettingsNavigationModel.self) private var navigation
    @Environment(\.shellDesktopEditorReady) private var ready

    init(settings: SettingsStore, controller: WMController) {
        _editor = State(initialValue: ShellDesktopEditor(
            configuration: controller.workspaceBarManager.shellConfiguration,
            settings: settings, controller: controller
        ))
    }

    init(editor: ShellDesktopEditor) {
        _editor = State(initialValue: editor)
    }

    var body: some View {
        VStack(spacing: 10) {
            ShellDesktopStyleStrip(editor: editor)
            scope
            SettingsTabs(
                selection: Binding(
                    get: { editor.surface },
                    set: { next in Task { await editor.selectSurface(next) } }
                ),
                tabs: [("Bar", .bar), ("Island", .island), ("Drawers", .drawers)]
            ) { surface in
                if surface == editor.surface {
                    switch surface {
                    case .bar:
                        VStack(spacing: 10) {
                            preview
                            ShellDesktopEditorForm(editor: editor)
                        }
                    case .island:
                        GeometryReader { geometry in
                            VStack(spacing: 8) {
                                islandPreview(height: min(
                                    expandedPreview ? 180 : 110,
                                    max(64, geometry.size.height * 0.32)
                                ))
                                ShellIslandEditorForm(editor: editor)
                            }
                        }
                    case .drawers:
                        GeometryReader { geometry in
                            VStack(spacing: 8) {
                                drawerPreview(height: min(
                                    ShellSettingsPreview.drawerHeight, max(64, geometry.size.height * 0.3)
                                ))
                                ShellDrawerEditorForm(editor: editor)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
        .task {
            editor.attach(navigation)
            await editor.open(navigation.route)
            if let ready {
                await editor.reload()
                await ready.action(editor)
            }
        }
        .task(id: editor.configuration.revision) { await editor.reload() }
        .onChange(of: navigation.route) { _, route in
            Task { await editor.open(route) }
        }
        .onDisappear { editor.detach() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) {
            _ in editor.refreshMonitors()
        }
        .confirmationDialog("Save changes before continuing?", isPresented: Binding(
            get: { editor.pendingTransition != nil }, set: { _ in }
        )) {
            Button("Save") { Task { await editor.resolve(.save) } }
            Button("Discard", role: .destructive) { Task { await editor.resolve(.discard) } }
            Button("Cancel", role: .cancel) { Task { await editor.resolve(.cancel) } }
        } message: {
            Text("Your unsaved changes stay here until you save or discard them.")
        }
    }

    private var scope: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                switch editor.scope {
                case .active:
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                case .previewing:
                    Text("Previewing \(editor.configuration.styleTitle(editor.selectedStyle))").fontWeight(.semibold)
                    Text("Active: \(editor.configuration.styleTitle(editor.activeStyle))").foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Use Style") { Task { await editor.useStyle() } }
                        .buttonStyle(.borderedProminent)
                }
                if editor.surface == .bar, editor.selectedWidget != nil {
                    Spacer(minLength: 4)
                    Button("Bar Settings") { Task { await editor.selectWidget(nil) } }
                } else if editor.surface == .island, editor.selectedComponent != nil {
                    Spacer(minLength: 4)
                    Button("Island Settings") { Task { await editor.selectComponent(nil) } }
                }
            }
            if let snapshot = editor.snapshot {
                HStack {
                    Picker("Palette", selection: Binding(
                        get: { snapshot.config.themeName }, set: { editor.selectTheme($0) }
                    )) {
                        ForEach(snapshot.themes, id: \.self) { Text(ShellStyleText.paletteTitle($0)).tag($0) }
                    }
                    if snapshot.config.themeName == ShellWallpaperPalette.themeName {
                        Picker("Color Scheme", selection: Binding(
                            get: { snapshot.config.wallpaperScheme }, set: { editor.selectScheme($0) }
                        )) {
                            ForEach(ShellWallpaperScheme.allCases, id: \.self) {
                                Text(ShellStyleText.paletteTitle($0.rawValue)).tag($0)
                            }
                        }
                    }
                    Text("Edits save to \(editor.configuration.styleTitle(editor.selectedStyle))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    private var preview: some View {
        VStack(spacing: 4) {
            HStack {
                Picker("Display", selection: Binding(
                    get: { editor.selectedMonitor }, set: { editor.selectMonitor($0) }
                )) {
                    Text("All Displays (sample preview)").tag(Optional<Monitor.ID>.none)
                    ForEach(editor.monitors) { monitor in
                        Text(monitor.isMain ? String(localized: "\(monitor.name) (Main)") : monitor.name)
                            .tag(Optional(monitor.id))
                    }
                }
                .frame(maxWidth: 360)
                Spacer(minLength: 0)
            }
            if let snapshot = editor.snapshot, let style = editor.previewStyle {
                ShellDesktopPreview(
                    config: snapshot.config, style: style, display: editor.previewDisplay,
                    sourceGeneration: editor.configuration.sourceGeneration,
                    fullWidth: editor.barOverride?.settings.fullWidth ?? editor.barSettings.fullWidth
                )
                .frame(height: style.vertical ? 136 : 52)
            } else {
                ProgressView().frame(maxWidth: .infinity).frame(height: 52)
            }
            Text(editor.monitor == nil
                ? String(localized: "Sample data and schematic geometry. Your desktop uses live information.")
                : String(localized: "Sample data at this display’s bar geometry."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder private func drawerPreview(height: CGFloat) -> some View {
        if let config = editor.drawerPreviewConfig, let drawer = editor.drawer {
            VStack(spacing: 4) {
                ShellDesktopPreview(
                    config: config, style: ShellBarStyle(), display: nil,
                    sourceGeneration: editor.configuration.sourceGeneration,
                    fullWidth: false, surface: .drawer(drawer.id)
                )
                .frame(height: height)
                Text("Sample data and panel layout. Hover settings change the trigger area, not the panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder private func islandPreview(height: CGFloat) -> some View {
        if let snapshot = editor.snapshot, editor.island != nil {
            VStack(spacing: 4) {
                HStack {
                    Text("Preview").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Preview", selection: $expandedPreview) {
                        Text("Compact").tag(false)
                        Text("Expanded").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                ShellDesktopPreview(
                    config: snapshot.config, style: ShellBarStyle(), display: nil,
                    sourceGeneration: editor.configuration.sourceGeneration,
                    fullWidth: editor.islandFullWidth, surface: .island(expanded: expandedPreview)
                )
                .frame(height: height)
                Text("Sample data. Your desktop uses live information.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
        }
    }
}

extension EnvironmentValues {
    @Entry var shellDesktopEditorReady: ShellDesktopEditorObserver?
}

@MainActor
final class ShellDesktopEditorObserver {
    let action: (ShellDesktopEditor) async -> Void

    init(_ action: @escaping (ShellDesktopEditor) async -> Void) {
        self.action = action
    }
}
