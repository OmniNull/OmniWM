// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct AdvancedSettingsPage: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var fileStatus: SettingsFileStatus?
    @State private var widget: String?
    @State private var sourceError: String?
    @State private var editingSource = false

    private var configuration: ShellConfigurationCoordinator {
        controller.workspaceBarManager.shellConfiguration
    }

    private var menu: StatusMenuModel? {
        controller.statusBarController?.settingsMenuModel
    }

    var body: some View {
        Form {
            Section("Configuration Files") {
                HStack {
                    Button("Reveal Settings File") { fileAction(.reveal) }
                    Button("Edit Settings File…") { fileAction(.open) }
                }
                if let fileStatus {
                    Label(fileStatus.message, systemImage: fileStatus.icon).foregroundStyle(fileStatus.color)
                }
            }
            .id("Configuration Files")
            Section("Shell Development") {
                HStack {
                    Button("Open Shell Folder…") { NSWorkspace.shared.open(configuration.shellDirectory) }
                    if let documentation = URL(string: "https://omniwm.app/features/luau-shell/") {
                        Link("Shell Documentation", destination: documentation)
                    }
                }
                let widgets =
                    Array(Set(configuration.config.directories
                            .flatMap { ShellConfig.widgetFolders(in: $0).map(\.lastPathComponent) })).sorted()
                Picker("Widget Source", selection: $widget) {
                    Text("Choose a widget").tag(String?.none)
                    ForEach(widgets, id: \.self) { name in
                        Text(ShellBarLayout.title(of: name)).tag(String?.some(name))
                    }
                }
                Button("Edit Widget Source…", action: editSource).disabled(widget == nil || editingSource)
                SettingsCaption(
                    localized: "Opens a persistent copy in your external editor. Visual options are available in Widgets."
                )
                if let sourceError { Label(sourceError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            .id("Shell Development")
            if let menu, menu.ipcMenuEnabled {
                Section("Automation") {
                    Toggle("Enable IPC", isOn: $settings.ipcEnabled)
                    SettingsCaption(localized: "Allows local commands and scripts to control OmniWM.")
                }
                .id("Automation")
                Section("Command-Line Tools") {
                    if let status = menu.cliStatus {
                        switch status {
                        case let .homebrewManaged(url):
                            LabeledContent("Managed by Homebrew", value: url.path)
                        case let .appManaged(url, onPath):
                            LabeledContent("Installed CLI", value: url.path)
                            if !onPath {
                                SettingsCaption(
                                    localized: "Add the CLI directory to your PATH to use omniwmctl in Terminal."
                                )
                            }
                            Button("Remove CLI from PATH…") { menu.removeCLI() }
                        case let .notInstalled(url, _):
                            LabeledContent("CLI Location", value: url.path)
                            Button("Install CLI to PATH…") { menu.installCLI() }
                        case let .conflict(url):
                            Label(
                                String(localized: "Another file occupies \(url.path)."),
                                systemImage: "exclamationmark.triangle"
                            )
                        }
                    }
                }
                .id("Command-Line Tools")
            }
        }
        .formStyle(.grouped)
        .task {
            do { try await configuration.refresh() }
            catch { sourceError = error.localizedDescription }
            menu?.refreshCLIStatus()
        }
    }

    private func fileAction(_ action: SettingsFileAction) {
        do { fileStatus = try SettingsFileWorkflow.perform(action, settings: settings) }
        catch { fileStatus = .error(error.localizedDescription) }
    }

    private func editSource() {
        guard let widget else { return }
        editingSource = true
        Task {
            defer { editingSource = false }
            do {
                _ = try await configuration.editFile { directory in
                    var problems: [String] = []
                    guard let config = ShellConfig.load(shellDirectory: directory, problems: &problems) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    return try ShellProfiles.eject(widget, config: config, shellDirectory: directory) != nil
                }
                let config = configuration.config
                let target = config.widget(widget)?.deletingLastPathComponent()
                    ?? config.file("widgets/\(widget)/component.luau")?.deletingLastPathComponent()
                guard let target else { throw CocoaError(.fileNoSuchFile) }
                let root = target.appendingPathComponent("init.luau")
                let source = FileManager.default.fileExists(atPath: root.path) ? root : target
                    .appendingPathComponent("component.luau")
                guard NSWorkspace.shared.open(source) else { throw CocoaError(.fileNoSuchFile) }
                sourceError = nil
            } catch { sourceError = error.localizedDescription }
        }
    }
}
