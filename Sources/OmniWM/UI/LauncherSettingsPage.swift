// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct LauncherEditorRequest: Identifiable {
    let id = UUID()
    var entry: LauncherEntry
    var runOnly = false
}

struct LauncherSettingsPage: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Bindable var navigation: SettingsNavigationModel
    @State private var execution = LauncherExecution.shared
    @State private var catalog = LauncherExecutableCatalog.shared
    @State private var showsDiscovery = false

    var body: some View {
        Form {
            Section("Saved Entries") {
                ForEach(settings.launcher.entries) { entry in
                    HStack {
                        Label(entry.name, systemImage: entry.symbol)
                        Spacer()
                        Text(entry.kind.title).foregroundStyle(.secondary)
                        Button("Run") { run(entry) }
                        if let bundleID = entry.bundleIdentifier {
                            Button("Configure Shortcut…") {
                                configureShortcut(bundleID: bundleID)
                            }
                        }
                        Button("Edit") { navigation.launcherEditorRequest = .init(entry: entry) }
                        Button("Remove", role: .destructive) {
                            controller.commandPaletteController.removeLauncherEntry(entry.id, settings: settings)
                        }
                    }
                }
                Menu("Add Entry…") {
                    ForEach([LauncherEntry.Kind.application, .command, .script], id: \.self) { kind in
                        Button(kind.title) { add(kind) }
                    }
                }
                SettingsCaption(localized: "Saved apps, commands, and scripts appear together in the Launcher.")
            }
            Section("Execution Defaults") {
                Picker("Shell", selection: $settings.launcher.shell) {
                    ForEach(LauncherShell.allCases.filter { $0 != .defaultShell }, id: \.self) { shell in
                        Text(shell.title).tag(shell)
                    }
                }
                .onChange(of: settings.launcher.shell) { _, _ in settings.launcher.shellExecutable = "" }
                Picker("Terminal", selection: $settings.launcher.terminal) {
                    ForEach(
                        LauncherTerminal.allCases.filter { $0 != .defaultTerminal && $0 != .background },
                        id: \.self
                    ) { Text($0.title).tag($0) }
                }
                SettingsCaption(localized: "Used by saved entries and CLI tools unless an entry overrides them.")
                SettingsCaption(
                    localized: "Commands open in a fresh session and keep their output visible. The built-in option requires the Ghostty Quake Terminal. Background execution is available per entry."
                )
            }
            .id("launcher-execution")
            Section {
                DisclosureGroup("Discovery and Advanced Options", isExpanded: $showsDiscovery) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("App Folders").font(.headline)
                        folderList($settings.launcher.appFolders)
                        SettingsCaption(
                            localized: "Standard app folders and active Nix profiles are included. Add custom folders for other apps, including Homebrew formula apps kept inside a keg."
                        )
                        Divider()
                        Text("Extra CLI Folders").font(.headline)
                        folderList($settings.launcher.cliFolders)
                        SettingsCaption(
                            localized: "CLI search uses the selected shell’s PATH, Homebrew, and active Nix profiles. Extra folders are searched after PATH."
                        )
                        Divider()
                        fileField("Custom Shell Executable", path: $settings.launcher.shellExecutable)
                    }
                    .padding(.vertical, 8)
                }
            }
            .id("launcher-discovery")
            Section {
                HStack {
                    Button("Refresh Launcher") {
                        ApplicationCatalogService.shared.refreshIfNeeded(
                            refreshMetadata: true, extraFolders: settings.launcher.appFolders
                        )
                        catalog.refresh(configuration: settings.launcher, force: true)
                    }
                    if catalog.isLoading { ProgressView().controlSize(.small) }
                }
                if let failure = catalog.failure { Text(failure).foregroundStyle(.red) }
            }
            if !execution.running.isEmpty {
                Section("Running") {
                    ForEach(execution.running.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                        HStack { ProgressView().controlSize(.small)
                            Text(execution.running[id] ?? "")
                        }
                    }
                }
            }
            if let outcome = execution.outcome {
                Section(outcome.name) {
                    Text(outcome.message).foregroundStyle(outcome.failed ? .red : .secondary)
                    if !outcome.output.isEmpty {
                        ScrollView {
                            Text(outcome.output).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 220)
                    }
                    Button("Dismiss") { execution.outcome = nil }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: navigation.route, initial: true) { _, route in
            if route.anchor == "launcher-discovery" { showsDiscovery = true }
        }
        .sheet(item: $navigation.launcherEditorRequest) { request in
            LauncherEntryEditor(
                entry: request.entry, runOnly: request.runOnly, configuration: settings.launcher,
                save: { entry in
                    if let index = settings.launcher.entries.firstIndex(where: { $0.id == entry.id }) {
                        settings.launcher.entries[index] = entry
                    } else {
                        settings.launcher.entries.append(entry)
                    }
                }, run: run
            )
        }
    }

    func configureShortcut(bundleID: String) {
        settings.reconcileDynamicHotkeys()
        navigation.request(SettingsRoute(section: .hotkeys, itemID: ActionCatalog.openAppPrefix + bundleID))
    }

    private func run(_ entry: LauncherEntry) {
        controller.commandPaletteController.actionExecutor.perform(.launchEntry(controller, entry, ""))
    }

    private func add(_ kind: LauncherEntry.Kind) {
        var entry = LauncherEntry()
        entry.kind = kind
        navigation.launcherEditorRequest = .init(entry: entry)
    }

    private func folderList(_ folders: Binding<[String]>) -> some View {
        VStack(alignment: .leading) {
            ForEach(folders.wrappedValue.indices, id: \.self) { index in
                HStack {
                    Text(folders.wrappedValue[index]).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove") { folders.wrappedValue.remove(at: index) }
                }
            }
            Button("Add Folder…") {
                if let path = LauncherEntryEditor.choosePath(directory: true), !folders.wrappedValue.contains(path) {
                    folders.wrappedValue.append(path)
                }
            }
        }
    }

    private func fileField(_ title: LocalizedStringKey, path: Binding<String>) -> some View {
        HStack {
            TextField(title, text: path, prompt: Text("Use the selected shell"))
            Button("Choose…") { if let value = LauncherEntryEditor.choosePath() { path.wrappedValue = value } }
        }
    }
}
