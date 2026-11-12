// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct AppThemingCustomSection: View {
    @Bindable var settings: AppThemingSettings
    let controller: WMController
    @Binding var editing: SettingsExport.AppTheming.Custom?
    @Binding var review: AppThemingReview?

    var body: some View {
        Section {
            ForEach(settings.values.custom) { custom in
                row(custom)
            }
            Button("Add Custom Template…") {
                editing = SettingsExport.AppTheming.Custom(name: "", template: "", output: "")
            }
        } header: {
            Text("Custom Templates")
        } footer: {
            SettingsCaption(
                localized: "A custom template writes one file inside ~/.config or ~/Library/Application Support, rendered for the current macOS appearance."
            )
        }
    }

    private func row(_ custom: SettingsExport.AppTheming.Custom) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: enabled(custom.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: custom.name)
                        SettingsCaption(reloadText(custom))
                    }
                }
                Button("Edit…") { editing = custom }
                Button(role: .destructive) {
                    settings.values.custom.removeAll { $0.id == custom.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(Text("Remove"))
            }
            HStack(spacing: 6) {
                Image(systemName: "doc.plaintext").foregroundStyle(.secondary)
                Text(verbatim: custom.template).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            }
            let preview = controller.appThemePreview
            AppThemingPaths(paths: preview.outputPaths(for: preview.target(for: custom)))
            if custom.enabled {
                AppThemingStatus(result: controller.appThemeService?.results[custom.targetID]) { replace(custom) }
            }
        }
        .padding(.vertical, 2)
    }

    private func reloadText(_ custom: SettingsExport.AppTheming.Custom) -> String {
        switch custom.reload {
        case .none: String(localized: "Writes the file only")
        case .ghostty: String(localized: "Then reloads Ghostty")
        case .kitty: String(localized: "Then reloads kitty")
        case .herdr: String(localized: "Then reloads herdr")
        }
    }

    private func enabled(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.values.custom.first { $0.id == id }?.enabled ?? false },
            set: { value in
                guard let index = settings.values.custom.firstIndex(where: { $0.id == id }) else { return }
                settings.values.custom[index].enabled = value
            }
        )
    }

    private func replace(_ custom: SettingsExport.AppTheming.Custom) {
        let preview = controller.appThemePreview
        guard let changes = try? preview.changes(for: preview.target(for: custom), onlyExisting: true) else {
            return
        }
        review = AppThemingReview(
            title: String(localized: "Replace Changed Files"),
            message: String(
                localized: "These files have changes OmniWM didn’t make. Replacing them keeps a backup of each."
            ),
            confirmTitle: String(localized: "Back Up and Replace"),
            changes: changes
        ) { [controller] in controller.appThemeService?.confirm(changes, reloading: custom.targetID) }
    }
}
