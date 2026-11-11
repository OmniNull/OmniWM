// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct WallpaperFolderRow: Identifiable, Equatable {
    let id: String
    let display: WallpaperDisplay?
    let name: String
    let folder: String
    let custom: Bool
    let count: Int
}

enum WallpaperRotationChoice: Hashable {
    case off
    case minutes(Int)
    case custom

    static let presets = [15, 30, 60]

    init(_ minutes: Int) {
        self = minutes <= 0 ? .off : Self.presets.contains(minutes) ? .minutes(minutes) : .custom
    }
}

struct WallpaperSettingsPage: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var rows: [WallpaperFolderRow] = []
    @State private var defaultCount = 0
    @State private var customRotation = false

    private var manager: WallpaperManager {
        controller.wallpaperManager
    }

    var body: some View {
        Form {
            Section("Wallpaper") {
                Toggle("Manage Wallpapers", isOn: Bindable(settings.wallpaper).enabled)
                    .id("Manage Wallpapers")
                    .help(String(localized: "Let OmniWM set each display’s wallpaper from a folder"))
                SettingsCaption(localized: """
                OmniWM sets each display’s wallpaper from a folder, shuffles through it and can change it on a \
                schedule. Turning this off leaves your current wallpapers as they are.
                """)
                if settings.wallpaper.enabled {
                    Button("Next Wallpaper on All Displays") {
                        Task { await manager.next(.all) }
                    }
                    .help(String(localized: "Show the next wallpaper from each display’s folder"))
                    if let problem = manager.problem {
                        SettingsCaption(problem)
                    }
                }
            }
            .id("Wallpaper")

            folders
            rotation
            WallpaperSchemeSection(settings: settings, controller: controller)
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .onChange(of: settings.wallpaper.export()) { _, _ in reload() }
        .onChange(of: manager.entries) { _, _ in reload() }
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification))
        { _ in
            reload()
        }
    }

    private var folders: some View {
        Section("Folders") {
            LabeledContent("Default Folder") {
                folderControls(
                    path: settings.wallpaper.folder, count: defaultCount, custom: false,
                    choose: { chooseDefaultFolder() }, reset: nil
                )
            }
            .id("Default Folder")
            .help(String(localized: "The folder every display uses unless you choose one for it"))
            ForEach(rows) { row in
                LabeledContent {
                    folderControls(
                        path: row.custom ? row.folder : String(localized: "Default folder"), count: row.count,
                        custom: row.custom, choose: row.display.map { display in { choose(for: display) } },
                        reset: row.custom ? { reset(row) } : nil
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                        Text(detail(row)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            SettingsCaption(localized: """
            Each display uses the default folder until you choose one for it. Displays are recognized by their \
            identity, so identical monitors keep separate folders, and a display you unplug keeps its folder.
            """)
        }
        .id("Folders")
    }

    private func folderControls(
        path: String, count: Int, custom: Bool, choose: (() -> Void)?, reset: (() -> Void)?
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(path).lineLimit(1).truncationMode(.middle).foregroundStyle(custom ? .primary : .secondary)
                Text("^[\(count) wallpaper](inflect: true)").font(.caption).foregroundStyle(.secondary)
            }
            if let choose {
                Button("Choose…", action: choose)
                    .help(String(localized: "Choose a folder of wallpapers"))
            }
            if let reset {
                Button("Reset to Default", action: reset)
                    .help(String(localized: "Use the default folder for this display again"))
            }
        }
    }

    private var rotation: some View {
        Section("Rotation") {
            Picker("Change Wallpaper", selection: Binding(
                get: { customRotation ? .custom : WallpaperRotationChoice(settings.wallpaper.rotationMinutes) },
                set: { choice in
                    switch choice {
                    case .off:
                        customRotation = false
                        manager.setRotation(0)
                    case let .minutes(value):
                        customRotation = false
                        manager.setRotation(value)
                    case .custom:
                        customRotation = true
                    }
                }
            )) {
                Text("Off").tag(WallpaperRotationChoice.off)
                Text("Every 15 Minutes").tag(WallpaperRotationChoice.minutes(15))
                Text("Every 30 Minutes").tag(WallpaperRotationChoice.minutes(30))
                Text("Every Hour").tag(WallpaperRotationChoice.minutes(60))
                Text("Custom").tag(WallpaperRotationChoice.custom)
            }
            .id("Change Wallpaper")
            if customRotation || WallpaperRotationChoice(settings.wallpaper.rotationMinutes) == .custom {
                Stepper(value: Binding(
                    get: { max(1, settings.wallpaper.rotationMinutes) },
                    set: { manager.setRotation($0) }
                ), in: 1 ... SettingsExport.Wallpaper.rotationLimit) {
                    LabeledContent("Minutes") {
                        TextField("Minutes", value: Binding(
                            get: { max(1, settings.wallpaper.rotationMinutes) },
                            set: { manager.setRotation($0) }
                        ), format: .number)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .id("Minutes")
            }
            LabeledContent("Next Change") {
                Text(nextChangeText).monospacedDigit().foregroundStyle(.secondary)
            }
            .id("Next Change")
            Picker("Placement", selection: Bindable(settings.wallpaper).placement) {
                Text("Fill Screen").tag(WallpaperPlacement.fill)
                Text("Fit to Screen").tag(WallpaperPlacement.fit)
            }
            .id("Placement")
            SettingsCaption(localized: "Rotation runs while OmniWM runs and keeps its time across restarts.")
        }
        .id("Rotation")
        .disabled(!settings.wallpaper.enabled)
    }

    private var nextChangeText: String {
        guard settings.wallpaper.enabled, let next = manager.nextChange else { return String(localized: "Off") }
        return next.formatted(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private func detail(_ row: WallpaperFolderRow) -> String {
        guard let display = row.display else { return String(localized: "Not connected") }
        var parts: [String] = []
        if display.isMain { parts.append(String(localized: "Main")) }
        if display.isBuiltin { parts.append(String(localized: "Built-in")) }
        parts.append("\(Int(display.size.width)) × \(Int(display.size.height))")
        return parts.joined(separator: " · ")
    }

    private func reload() {
        let home = NSHomeDirectory()
        let fallback = WallpaperLibrary.folderURL(settings.wallpaper.folder, home: home)
        defaultCount = fallback.map { WallpaperLibrary.files(in: $0).count } ?? 0
        let connected = manager.desktop.displays()
        var next = connected.map { display -> WallpaperFolderRow in
            let own = settings.wallpaper.folder(for: display.monitor)
            let folder = own.flatMap { WallpaperLibrary.folderURL($0.folder, home: home) }
            return WallpaperFolderRow(
                id: display.key, display: display, name: display.name,
                folder: own?.folder ?? settings.wallpaper.folder, custom: own != nil,
                count: (folder ?? fallback).map { WallpaperLibrary.files(in: $0).count } ?? 0
            )
        }
        for entry in settings.wallpaper.displays where !connected.contains(where: {
            settings.wallpaper.folder(for: $0.monitor)?.id == entry.id
        }) {
            let folder = WallpaperLibrary.folderURL(entry.folder, home: home)
            next.append(WallpaperFolderRow(
                id: entry.id.uuidString, display: nil, name: entry.monitorName, folder: entry.folder, custom: true,
                count: folder.map { WallpaperLibrary.files(in: $0).count } ?? 0
            ))
        }
        rows = next
    }

    private func chooseDefaultFolder() {
        let current = WallpaperLibrary.folderURL(settings.wallpaper.folder)
        guard let url = WallpaperManager.chooseFolder(startingAt: current) else { return }
        settings.wallpaper.folder = WallpaperLibrary.abbreviate(url.standardizedFileURL.path)
    }

    private func choose(for display: WallpaperDisplay) {
        let start = settings.wallpaper.folder(for: display.monitor).flatMap { WallpaperLibrary.folderURL($0.folder) }
            ?? WallpaperLibrary.folderURL(settings.wallpaper.folder)
        guard let url = WallpaperManager.chooseFolder(startingAt: start) else { return }
        settings.wallpaper.setFolder(WallpaperLibrary.abbreviate(url.standardizedFileURL.path), for: display.monitor)
    }

    private func reset(_ row: WallpaperFolderRow) {
        if let display = row.display {
            settings.wallpaper.setFolder(nil, for: display.monitor)
        } else {
            settings.wallpaper.displays.removeAll { $0.id.uuidString == row.id }
        }
    }
}

struct WallpaperSchemeSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Environment(\.colorScheme) private var colorScheme

    private var state: WallpaperPaletteState {
        controller.workspaceBarManager.wallpaperPaletteState
    }

    var body: some View {
        Section("Colors") {
            Toggle("Match Colors to Wallpaper", isOn: Binding(
                get: { state.active },
                set: { on in
                    if on {
                        controller.workspaceBarManager.selectWallpaperScheme(state.scheme)
                    } else {
                        controller.workspaceBarManager.useStylePalette()
                    }
                }
            ))
            .id("Match Colors to Wallpaper")
            .help(String(localized: "Color the bar, island and popouts from the main display’s wallpaper"))
            SettingsCaption(localized: """
            Uses the main display’s wallpaper. When OmniWM changes the wallpaper, the colors change at the same \
            moment. This is the same Wallpaper Colors palette as in Styles & Widgets.
            """)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(swatches, id: \.scheme) { swatch in
                    schemeTile(swatch)
                }
            }
            .id("Color Scheme")
            .padding(.vertical, 4)
            if swatches.isEmpty || controller.wallpaperManager.paletteSample == nil {
                SettingsCaption(localized: "Previews appear once OmniWM can read the main display’s wallpaper.")
            }
        }
        .id("Colors")
        .task { await controller.wallpaperManager.sampleMainWallpaper() }
    }

    private var swatches: [ShellWallpaper.Swatch] {
        if let pixels = controller.wallpaperManager.paletteSample {
            return ShellWallpaperPalette.swatches(pixels: pixels)
        }
        return ShellWallpaperScheme.allCases.map {
            ShellWallpaper.Swatch(scheme: $0.rawValue, light: [], dark: [])
        }
    }

    private func schemeTile(_ swatch: ShellWallpaper.Swatch) -> some View {
        let selected = state.active && state.scheme.rawValue == swatch.scheme
        let colors = colorScheme == .dark ? swatch.dark : swatch.light
        let title = ShellStyleText.paletteTitle(swatch.scheme)
        return Button {
            if let scheme = ShellWallpaperScheme(rawValue: swatch.scheme) {
                controller.workspaceBarManager.selectWallpaperScheme(scheme)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 3) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { _, hex in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(NSColor(shellHex: hex).map { Color(nsColor: $0) } ?? Color.secondary)
                            .frame(height: 22)
                    }
                    if colors.isEmpty {
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 22)
                    }
                }
                HStack {
                    Text(title).font(.callout.weight(selected ? .semibold : .regular))
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1
            ))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(String(localized: "Color OmniWM with the \(title) scheme"))
    }
}
