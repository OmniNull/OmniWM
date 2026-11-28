// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LauncherEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: LauncherEntry
    @State private var argumentSources: [Int?]
    let runOnly: Bool
    var configuration = LauncherConfiguration()
    let save: (LauncherEntry, [Int?]) -> Void
    let run: (LauncherEntry) -> Void
    @State private var showsAdvanced = false
    @State private var inheritedShellName: String?
    @State private var lastRunName: String?
    @State private var execution = LauncherExecution.shared

    init(
        entry: LauncherEntry, runOnly: Bool, configuration: LauncherConfiguration = LauncherConfiguration(),
        save: @escaping (LauncherEntry, [Int?]) -> Void, run: @escaping (LauncherEntry) -> Void
    ) {
        _entry = State(initialValue: entry)
        _argumentSources = State(initialValue: entry.arguments.indices.map(Optional.some))
        self.runOnly = runOnly
        self.configuration = configuration
        self.save = save
        self.run = run
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(runOnly ? String(localized: "Run CLI") : String(localized: "Launcher Entry"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(entry.kind.title).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Name") {
                        TextField("Name", text: $entry.name, prompt: Text("Name in Launcher"))
                            .accessibilityIdentifier("launcher-entry-name")
                    }
                    .settingsField(.launcherEntries, row: entry.id.uuidString, leaf: "name")
                    if entry.kind == .command {
                        field("Command") {
                            TextField(
                                "Command",
                                text: $entry.command,
                                prompt: Text("Enter a command…"),
                                axis: .vertical
                            )
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.leading)
                            .lineLimit(3 ... 8)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("launcher-entry-command")
                        }
                        .settingsField(.launcherEntries, row: entry.id.uuidString, leaf: "command")
                    } else {
                        pathField(
                            entry.kind == .application ? "Application" : "File", path: $entry.path,
                            prompt: entry
                                .kind == .application ? "Choose an application" : "Path to a script or executable",
                            application: entry.kind == .application, autoName: true
                        )
                        .settingsField(.launcherEntries, row: entry.id.uuidString, leaf: "path")
                    }
                    if entry.kind != .application { executionFields }
                    DisclosureGroup("Advanced Options", isExpanded: $showsAdvanced) {
                        advancedFields.padding(.top, 12)
                    }
                    .accessibilityIdentifier("launcher-entry-advanced")
                }
                .textFieldStyle(.roundedBorder)
                .padding(.trailing, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
            if let outcome = execution.outcome, outcome.name == lastRunName {
                Label(outcome.message, systemImage: outcome.failed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(outcome.failed ? .red : .secondary)
                    .textSelection(.enabled)
            }
            actions
        }
        .padding(20)
        .frame(width: 620, height: 600)
        .onAppear(perform: updateInheritedShellName)
        .onChange(of: configuration.shell) { _, _ in updateInheritedShellName() }
        .onChange(of: configuration.shellExecutable) { _, _ in updateInheritedShellName() }
    }

    private var valid: Bool {
        !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(entry.kind == .command ? entry.command : entry.path).trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    @ViewBuilder
    private var executionFields: some View {
        if entry.kind == .script || entry.kind == .executable {
            VStack(alignment: .leading, spacing: 8) {
                Text("Arguments").fontWeight(.medium)
                ForEach(entry.arguments.indices, id: \.self) { index in
                    HStack {
                        TextField(
                            "Argument",
                            text: Binding(
                                get: { entry.arguments.indices.contains(index) ? entry.arguments[index] : "" },
                                set: { if entry.arguments.indices.contains(index) { entry.arguments[index] = $0 } }
                            ),
                            prompt: Text("Argument value")
                        )
                        Button("Remove") {
                            entry.arguments.remove(at: index)
                            argumentSources.remove(at: index)
                        }
                    }
                }
                Button("Add Argument") {
                    entry.arguments.append("")
                    argumentSources.append(nil)
                }
            }
            .settingsField(.launcherEntries, row: entry.id.uuidString, leaf: "arguments")
            if entry.kind == .script {
                pathField("Interpreter (optional)", path: $entry.interpreter, prompt: "Use the script’s shebang")
                    .settingsField(.launcherEntries, row: entry.id.uuidString, leaf: "interpreter")
            }
        }
        pathField("Working Folder", path: $entry.workingDirectory, prompt: "Home folder", directory: true)
            .settingsField(.launcherEntries, row: entry.id.uuidString, leaf: "workingDirectory")
        HStack(alignment: .top, spacing: 16) {
            field("Run In") {
                Picker("Run In", selection: $entry.terminal) {
                    ForEach(LauncherTerminal.allCases, id: \.self) { terminal in
                        Text(terminal == .defaultTerminal
                            ? String(localized: "Default — \(configuration.terminal.title)") : terminal.title)
                            .tag(terminal)
                    }
                }
            }
            .settingsField(.launcherEntries, row: entry.id.uuidString, leaf: "terminal")
            field(entry.kind == .command ? "Command Shell" : "Environment Shell") {
                Picker("Shell", selection: $entry.shell) {
                    ForEach(LauncherShell.allCases, id: \.self) { shell in
                        Text(shell == .defaultShell
                            ? String(localized: "Default — \(inheritedShellName ?? configuration.shell.title)") : shell
                            .title)
                            .tag(shell)
                    }
                }
                .onChange(of: entry.shell) { _, _ in entry.shellExecutable = "" }
            }
            .settingsField(.launcherEntries, row: entry.id.uuidString, leaf: "shell", "shellExecutable")
        }
        .pickerStyle(.menu)
    }

    private var advancedFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !runOnly {
                field("Entry Type") {
                    Picker("Entry Type", selection: $entry.kind) {
                        ForEach(LauncherEntry.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                .settingsField(.launcherEntries, row: entry.id.uuidString, leaf: "kind")
            }
            field("Search Keywords") {
                TextField("Search Keywords", text: $entry.keywords, prompt: Text("Optional search terms"))
            }
            .settingsField(.launcherEntries, row: entry.id.uuidString, leaf: "keywords")
            if entry.kind != .application {
                pathField("Custom Shell Executable", path: $entry.shellExecutable, prompt: "Use the selected shell")
                    .settingsField(.launcherEntries, row: entry.id.uuidString, leaf: "shellExecutable")
            }
        }
    }

    private var actions: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("launcher-entry-cancel")
            Spacer()
            if runOnly {
                saveButton.buttonStyle(.bordered)
                runButton.buttonStyle(.borderedProminent)
            } else {
                runButton.buttonStyle(.bordered)
                saveButton.buttonStyle(.borderedProminent)
            }
        }
    }

    private var runButton: some View {
        Button(runOnly ? "Run" : "Run Now") {
            if !runOnly {
                lastRunName = entry.name
                execution.outcome = nil
            }
            run(entry)
            if runOnly { dismiss() }
        }
        .disabled(!valid)
        .keyboardShortcut(runOnly ? .defaultAction : nil)
        .accessibilityIdentifier("launcher-entry-run")
    }

    private var saveButton: some View {
        Button(runOnly ? "Save Entry" : "Save") {
            save(entry, argumentSources)
            dismiss()
        }
        .disabled(!valid)
        .keyboardShortcut(runOnly ? nil : .defaultAction)
        .accessibilityIdentifier("launcher-entry-save")
        .settingsField(.launcherEntries, row: entry.id.uuidString)
    }

    private func field<Content: View>(
        _ title: LocalizedStringKey, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).fontWeight(.medium)
            content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pathField(
        _ title: LocalizedStringKey, path: Binding<String>, prompt: LocalizedStringKey,
        application: Bool = false, directory: Bool = false, autoName: Bool = false
    ) -> some View {
        field(title) {
            HStack {
                TextField(title, text: path, prompt: Text(prompt))
                    .autocorrectionDisabled()
                Button("Choose…") {
                    guard let value = Self.choosePath(application: application, directory: directory) else { return }
                    path.wrappedValue = value
                    if autoName, entry.name.isEmpty {
                        entry.name = URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
                    }
                }
            }
        }
    }

    private func updateInheritedShellName() {
        inheritedShellName = (try? LauncherPaths.shell(
            configuration.shell, executable: configuration.shellExecutable
        ))?.kind.title
    }

    static func choosePath(application: Bool = false, directory: Bool = false) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = false
        if application { panel.allowedContentTypes = [.applicationBundle] }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
