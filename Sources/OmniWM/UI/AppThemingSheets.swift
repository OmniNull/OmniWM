// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct AppThemingReviewSheet: View {
    let review: AppThemingReview
    let backupFolder: String
    let onFinish: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: review.title).font(.title3.weight(.semibold))
            Text(verbatim: review.message).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(review.changes) { change in
                        AppThemingDiffView(change: change)
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 420)
            Text("A copy of each file is saved in \(backupFolder) before anything changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(review.confirmTitle) {
                    do {
                        try review.action()
                        onFinish(nil)
                    } catch {
                        onFinish(error.localizedDescription)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

struct AppThemingDiffView: View {
    let change: AppThemeChange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                Text(verbatim: change.display).font(.callout.monospaced()).textSelection(.enabled)
                if change.before == nil {
                    Text("New file").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let note = change.note {
                Label { Text(verbatim: note).font(.caption) } icon: {
                    Image(systemName: "info.circle")
                }
                .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(change.diff) { line in
                    row(line)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
    }

    private func row(_ line: AppThemeDiffLine) -> some View {
        let (mark, tint): (String, Color) = switch line.kind {
        case .added: ("+", .green)
        case .removed: ("-", .red)
        case .context: (" ", .clear)
        case .gap: ("⋯", .clear)
        }
        return HStack(spacing: 6) {
            Text(verbatim: mark).foregroundStyle(.secondary).frame(width: 10)
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .context || line.kind == .gap ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .background(tint.opacity(0.15))
        .accessibilityLabel(Text(verbatim: "\(mark) \(line.text)"))
    }
}

struct AppThemingCustomEditor: View {
    @State var custom: SettingsExport.AppTheming.Custom
    let policy: AppThemeOutputPolicy
    let onSave: (SettingsExport.AppTheming.Custom) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            (isNew ? Text("Add Custom Template") : Text("Edit Custom Template"))
                .font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $custom.name)
                fileRow("Template", path: $custom.template, save: false)
                fileRow("Dark Template (optional)", path: darkTemplate, save: false)
                fileRow("Output File", path: $custom.output, save: true)
                if let problem = outputProblem {
                    Label { Text(verbatim: problem).font(.caption) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                }
                Picker("After Writing", selection: $custom.reload) {
                    Text("Do Nothing").tag(AppThemeCustomReload.none)
                    Text("Reload Ghostty").tag(AppThemeCustomReload.ghostty)
                    Text("Reload kitty").tag(AppThemeCustomReload.kitty)
                    Text("Reload herdr").tag(AppThemeCustomReload.herdr)
                }
                if custom.reload == .none {
                    SettingsCaption(localized: "The app has to watch this file itself, or you reload it by hand.")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(custom)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            isNew = custom.name.isEmpty
        }
    }

    private var darkTemplate: Binding<String> {
        Binding(get: { custom.darkTemplate ?? "" }, set: { custom.darkTemplate = $0.isEmpty ? nil : $0 })
    }

    private var outputProblem: String? {
        guard !custom.output.isEmpty else { return nil }
        do {
            _ = try policy.destination(for: custom.output)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var canSave: Bool {
        !custom.name.trimmingCharacters(in: .whitespaces).isEmpty && !custom.template.isEmpty
            && !custom.output.isEmpty && outputProblem == nil
    }

    private func fileRow(_ title: LocalizedStringKey, path: Binding<String>, save: Bool) -> some View {
        HStack {
            TextField(
                title,
                text: path,
                prompt: Text(verbatim: save ? "~/.config/app/omniwm.conf" : "~/.config/omniwm/app-themes/app.conf")
            )
            Button("Choose…") {
                if let url = choose(save: save, current: path.wrappedValue) {
                    path.wrappedValue = policy.display(url)
                }
            }
        }
    }

    private func choose(save: Bool, current: String) -> URL? {
        if save {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.directoryURL = policy.configHome
            return panel.runModal() == .OK ? panel.url : nil
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = current.isEmpty ? policy.configHome : URL(fileURLWithPath: policy.expand(current))
            .deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }
}
