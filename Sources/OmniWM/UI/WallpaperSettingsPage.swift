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
    let list: WallpaperFolderList?
}

enum WallpaperRotationChoice: Hashable {
    case off
    case minutes(Int)
    case custom

    static let presets = SettingsExport.Wallpaper.rotationPresets

    init(_ minutes: Int, customAt: Int? = nil) {
        if customAt == minutes {
            self = .custom
        } else {
            self = minutes <= 0 ? .off : Self.presets.contains(minutes) ? .minutes(minutes) : .custom
        }
    }
}

@MainActor
struct WallpaperFolderChoice {
    let settings: WallpaperSettings
    var home = NSHomeDirectory()

    func setDefault(_ url: URL) {
        guard settings.enabled else { return }
        settings.folder = WallpaperLibrary.abbreviate(url.standardizedFileURL.path, home: home)
    }

    func set(_ url: URL?, for monitor: Monitor) {
        guard settings.enabled else { return }
        settings.setFolder(
            url.map { WallpaperLibrary.abbreviate($0.standardizedFileURL.path, home: home) }, for: monitor
        )
    }

    func forget(_ id: String) {
        guard settings.enabled else { return }
        settings.displays.removeAll { $0.id.uuidString == id }
    }
}

struct WallpaperSettingsPage: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var customAt: Int?

    private var manager: WallpaperManager? {
        controller.wallpaperManager
    }

    private var choice: WallpaperFolderChoice {
        WallpaperFolderChoice(settings: settings.wallpaper)
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
                if let manager {
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
        .onAppear { manager?.listsEveryFolder = true }
        .onChange(of: manager.map(ObjectIdentifier.init)) { _, _ in manager?.listsEveryFolder = true }
        .onDisappear { manager?.listsEveryFolder = false }
    }

    private var folders: some View {
        Section("Folders") {
            LabeledContent("Default Folder") {
                folderControls(
                    path: settings.wallpaper.folder, list: defaultList, custom: false,
                    choose: { chooseDefaultFolder() }, reset: nil
                )
            }
            .id("Default Folder")
            .help(String(localized: "The folder every display uses unless you choose one for it"))
            ForEach(rows) { row in
                LabeledContent {
                    folderControls(
                        path: row.custom ? row.folder : String(localized: "Default folder"), list: row.list,
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
        .disabled(!settings.wallpaper.enabled)
    }

    private func folderControls(
        path: String, list: WallpaperFolderList?, custom: Bool, choose: (() -> Void)?, reset: (() -> Void)?
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(path).lineLimit(1).truncationMode(.middle).foregroundStyle(custom ? .primary : .secondary)
                if let failure = list?.failure {
                    Text("Can’t be read: \(failure)").font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if let list {
                    Text("^[\(list.files.count) wallpaper](inflect: true)").font(.caption).foregroundStyle(.secondary)
                }
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
                get: { rotationChoice },
                set: { choice in
                    switch choice {
                    case .off:
                        customAt = nil
                        manager?.setRotation(0)
                    case let .minutes(value):
                        customAt = nil
                        manager?.setRotation(value)
                    case .custom:
                        customAt = settings.wallpaper.rotationMinutes
                    }
                }
            )) {
                Text("Off").tag(WallpaperRotationChoice.off)
                ForEach(WallpaperRotationChoice.presets, id: \.self) { minutes in
                    Text(Self.presetTitle(minutes)).tag(WallpaperRotationChoice.minutes(minutes))
                }
                Text("Custom").tag(WallpaperRotationChoice.custom)
            }
            .id("Change Wallpaper")
            if rotationChoice == .custom {
                Stepper(value: customMinutes, in: 1 ... SettingsExport.Wallpaper.rotationLimit) {
                    LabeledContent("Minutes") {
                        TextField("Minutes", value: customMinutes, format: .number)
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

    static func presetTitle(_ minutes: Int) -> String {
        String(localized: "Every \(minutes) Minutes")
    }

    private var rotationChoice: WallpaperRotationChoice {
        WallpaperRotationChoice(settings.wallpaper.rotationMinutes, customAt: customAt)
    }

    private var customMinutes: Binding<Int> {
        Binding(get: { max(1, settings.wallpaper.rotationMinutes) }, set: { minutes in
            manager?.setRotation(minutes)
            customAt = settings.wallpaper.rotationMinutes
        })
    }

    private var nextChangeText: String {
        guard let next = manager?.nextChange else { return String(localized: "Off") }
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

    private func list(_ folder: String) -> WallpaperFolderList? {
        guard let manager else { return nil }
        return WallpaperLibrary.folderURL(folder, home: manager.environment.home).flatMap(manager.list(for:))
    }

    private var defaultList: WallpaperFolderList? {
        list(settings.wallpaper.folder)
    }

    private var rows: [WallpaperFolderRow] {
        var rows: [WallpaperFolderRow] = []
        var connected: Set<UUID> = []
        for entry in manager?.entries ?? [] {
            let own = settings.wallpaper.folder(for: entry.display.monitor)
            if let own { connected.insert(own.id) }
            rows.append(WallpaperFolderRow(
                id: entry.display.key, display: entry.display, name: entry.display.name,
                folder: own?.folder ?? settings.wallpaper.folder, custom: own != nil,
                list: WallpaperFolderList(files: entry.files, failure: entry.failure)
            ))
        }
        for entry in settings.wallpaper.displays where !connected.contains(entry.id) {
            rows.append(WallpaperFolderRow(
                id: entry.id.uuidString, display: nil, name: entry.monitorName, folder: entry.folder, custom: true,
                list: list(entry.folder)
            ))
        }
        return rows
    }

    private func chooseDefaultFolder() {
        let current = WallpaperLibrary.folderURL(settings.wallpaper.folder)
        guard let url = WallpaperManager.chooseFolder(startingAt: current) else { return }
        choice.setDefault(url)
    }

    private func choose(for display: WallpaperDisplay) {
        let start = settings.wallpaper.folder(for: display.monitor).flatMap { WallpaperLibrary.folderURL($0.folder) }
            ?? WallpaperLibrary.folderURL(settings.wallpaper.folder)
        guard let url = WallpaperManager.chooseFolder(startingAt: start) else { return }
        choice.set(url, for: display.monitor)
    }

    private func reset(_ row: WallpaperFolderRow) {
        if let display = row.display {
            choice.set(nil, for: display.monitor)
        } else {
            choice.forget(row.id)
        }
    }
}
