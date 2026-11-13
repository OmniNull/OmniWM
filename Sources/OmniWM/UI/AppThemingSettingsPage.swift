// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct AppThemingReview: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let changes: [AppThemeChange]
    let action: () throws -> Void
}

struct AppThemingSettingsPage: View {
    @Bindable var settings: SettingsStore
    let controller: WMController
    @State private var review: AppThemingReview?
    @State private var editing: SettingsExport.AppTheming.Custom?
    @State private var problem: String?
    @State private var previewDark: Bool?
    @State private var page = AppThemingPageState()

    private var service: AppThemeService? {
        controller.appThemeService
    }

    private var preview: AppThemePreview {
        controller.appThemePreview
    }

    var body: some View {
        let preview = preview
        return Form {
            Section {
                AppThemePalettePreview(palette: preview.palette(), dark: previewDark ?? preview.dark)
                Picker("Preview", selection: previewBinding) {
                    Text("Light").tag(false)
                    Text("Dark").tag(true)
                }
                .pickerStyle(.segmented)
                Picker("Terminal Colors", selection: terminalColorsBinding) {
                    Text("Follow Palette").tag(AppThemeTerminalColors.palette)
                    Text("Standard Hues").tag(AppThemeTerminalColors.standard)
                }
                SettingsCaption(
                    localized: "Follow Palette takes terminal colors from a wallpaper palette’s accents, so the terminal matches the wallpaper, though red and green may not look red and green in diffs. Standard Hues keeps familiar red, green, yellow, blue, magenta and cyan for ls and git, tinted toward the accent. A theme with its own terminal hues keeps them with Follow Palette."
                )
                HStack {
                    SettingsCaption(
                        localized: "Apps update the moment OmniWM’s palette or macOS light and dark changes."
                    )
                    Spacer()
                    if service?.isRunning == true { ProgressView().controlSize(.small) }
                    Button("Apply Now") { service?.applyNow() }
                        .disabled(service?.palette == nil)
                }
            } header: {
                Text("Palette")
            }
            Section {
                ForEach(AppThemeBuiltIn.allCases) { app in
                    builtInRow(app, preview: preview)
                }
            } header: {
                Text("Apps")
            } footer: {
                SettingsCaption(
                    localized: "Nothing is on until you turn it on. OmniWM only writes the files listed here, and asks before it changes an app’s own settings file."
                )
            }
            AppThemingCustomSection(
                settings: settings.appTheming,
                controller: controller,
                paths: page.paths,
                editing: $editing,
                onReplace: { reviewConflict(preview.target(for: $0)) }
            )
            AppThemingPlaceholderHelp()
        }
        .formStyle(.grouped)
        .onAppear { refreshGhosttySelection() }
        .onChange(of: service?.results) { _, _ in refreshGhosttySelection() }
        .onChange(of: settings.appTheming.values) { _, _ in
            page.invalidateReview()
            refreshGhosttySelection()
        }
        .onDisappear { page.invalidateReview() }
        .onChange(of: service?.reviewAgain) { _, target in
            guard let target else { return }
            service?.reviewShown()
            if target == AppThemeService.ghosttySelectionReview {
                reviewGhosttySelection()
            } else {
                reviewAgain(target)
            }
        }
        .onChange(of: service?.problem) { _, failure in
            guard let failure else { return }
            service?.problemShown()
            problem = failure
        }
        .sheet(item: $review) { review in
            AppThemingReviewSheet(review: review, backupFolder: backupFolder) { error in
                problem = error
                refreshGhosttySelection()
            }
        }
        .sheet(item: $editing) { custom in
            AppThemingCustomEditor(custom: custom, policy: controller.appThemeEngine.policy) { saved in
                var values = settings.appTheming.values
                if let index = values.custom.firstIndex(where: { $0.id == saved.id }) {
                    values.custom[index] = saved
                } else {
                    values.custom.append(saved)
                }
                settings.appTheming.values = values
            }
        }
        .alert("App Theming", isPresented: problemBinding) {
            Button("OK") { problem = nil }
        } message: {
            Text(verbatim: problem ?? "")
        }
    }

    private var backupFolder: String {
        page.backupFolder
    }

    private var previewBinding: Binding<Bool> {
        Binding(get: { previewDark ?? preview.dark }, set: { previewDark = $0 })
    }

    private var problemBinding: Binding<Bool> {
        Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
    }

    @ViewBuilder
    private func builtInRow(_ app: AppThemeBuiltIn, preview: AppThemePreview) -> some View {
        let target = preview.target(for: app)
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: enabledBinding(app)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: app.name)
                    SettingsCaption(reloadDescription(app))
                }
            }
            AppThemingPaths(paths: page.paths[target.id] ?? [])
            if settings.appTheming.values.isEnabled(app) {
                AppThemingStatus(result: service?.results[app.id]) { reviewConflict(target) }
                extras(app)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func extras(_ app: AppThemeBuiltIn) -> some View {
        switch app {
        case .ghostty:
            switch page.ghosttyStatus {
            case .selected:
                EmptyView()
            case .notSelected:
                HStack {
                    Text(verbatim: AppThemeBuiltIn.ghosttyThemeLine)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button("Add to Ghostty Config…") { reviewGhosttySelection() }
                }
                SettingsCaption(localized: "Ghostty uses these themes once its config selects them.")
            case let .overridden(path):
                HStack(alignment: .firstTextBaseline) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Another Ghostty config sets a different theme").font(.caption)
                            Text(verbatim: path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Fix Ghostty Config…") { reviewGhosttySelection() }
                }
            case let .unreadable(path):
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OmniWM can’t read this Ghostty config, so it can’t tell which theme Ghostty uses")
                            .font(.caption)
                        Text(verbatim: path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        case .kitty:
            SettingsCaption(
                localized: "kitty 0.38 or newer loads these files by itself and switches them with macOS light and dark."
            )
        case .herdr:
            Toggle("Also reload saved herdr machines", isOn: herdrMachinesBinding)
            SettingsCaption(
                localized: "A herdr client attached to another machine draws with this terminal’s colors, so OmniWM reloads every enabled saved machine after the terminal."
            )
        case .neovim:
            neovimActivation
        }
    }

    private func reloadDescription(_ app: AppThemeBuiltIn) -> String {
        switch app {
        case .ghostty: String(localized: "Light and dark themes · reloads Ghostty 1.2 or newer with SIGUSR2")
        case .kitty: String(localized: "Automatic light and dark themes · reloads kitty with SIGUSR1")
        case .herdr: String(
                localized: "The [theme.custom] table of herdr’s config · reloads herdr through its socket API"
            )
        case .neovim: String(
                localized: "A base16 module for the current appearance · reloads Neovim with SIGUSR1"
            )
        }
    }

    private func enabledBinding(_ app: AppThemeBuiltIn) -> Binding<Bool> {
        Binding(
            get: { settings.appTheming.values.isEnabled(app) },
            set: { enabled in
                guard enabled else {
                    settings.appTheming.values.setEnabled(app, false)
                    return
                }
                turnOn(app)
            }
        )
    }

    private var neovimActivation: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: AppThemeNeovim.pluginLine)
                    Text(verbatim: AppThemeNeovim.setupLine)
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        AppThemeNeovim.pluginLine + "\n" + AppThemeNeovim.setupLine,
                        forType: .string
                    )
                }
            }
            SettingsCaption(
                localized: "Add the base16-nvim plugin to your plugin list and the setup line to your init.lua. OmniWM never edits your Neovim config; it signals running Neovim instances to reload the module."
            )
            Link("App Theming guide", destination: AppThemeNeovim.guideURL)
                .font(.caption)
        }
    }

    private var terminalColorsBinding: Binding<AppThemeTerminalColors> {
        Binding(
            get: { settings.appTheming.values.terminalColors },
            set: { settings.appTheming.values.terminalColors = $0 }
        )
    }

    private var herdrMachinesBinding: Binding<Bool> {
        Binding(
            get: { settings.appTheming.values.herdr.reloadSavedMachines },
            set: { settings.appTheming.values.herdr.reloadSavedMachines = $0 }
        )
    }
}

extension AppThemingSettingsPage {
    private func turnOn(_ app: AppThemeBuiltIn) {
        let preview = preview
        page.review(preview, target: preview.target(for: app)) { result in
            do {
                let changes = try result.get()
                guard !changes.isEmpty else {
                    settings.appTheming.values.setEnabled(app, true)
                    return
                }
                review = AppThemingReview(
                    title: String(localized: "Turn On \(app.name)"),
                    message: String(
                        localized: "OmniWM will change these existing files and keep them updated when the palette changes."
                    ),
                    confirmTitle: String(localized: "Back Up and Turn On"),
                    changes: changes
                ) { [controller] in controller.turnOnAppTheme(app, approving: changes) }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func reviewConflict(_ target: AppThemeTarget) {
        page.review(preview, target: target) { result in
            do {
                let changes = try result.get()
                review = AppThemingReview(
                    title: String(localized: "Replace Changed Files"),
                    message: String(
                        localized: "These files have changes OmniWM didn’t make. Replacing them keeps a backup of each."
                    ),
                    confirmTitle: String(localized: "Back Up and Replace"),
                    changes: changes
                ) { [service] in service?.confirm(changes, reloading: target.id) }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func reviewAgain(_ targetID: String) {
        let preview = preview
        if let app = AppThemeBuiltIn(rawValue: targetID) {
            reviewConflict(preview.target(for: app))
        } else if let custom = settings.appTheming.values.custom.first(where: { $0.targetID == targetID }) {
            reviewConflict(preview.target(for: custom))
        }
    }

    private func reviewGhosttySelection() {
        page.review(preview) { result in
            do {
                let changes = try result.get()
                guard !changes.isEmpty else {
                    refreshGhosttySelection()
                    return
                }
                review = AppThemingReview(
                    title: String(localized: "Select the OmniWM Themes in Ghostty"),
                    message: String(
                        localized: "Ghostty reads each of these files in turn, and the last theme line wins. OmniWM will select its themes and comment out every other theme line."
                    ),
                    confirmTitle: String(localized: "Back Up and Change"),
                    changes: changes
                ) { [service] in service?.applyGhosttySelection(changes) }
            } catch {
                problem = error.localizedDescription
                refreshGhosttySelection()
            }
        }
    }

    private func refreshGhosttySelection() {
        let preview = preview
        let targets = AppThemeBuiltIn.allCases.map(preview.target(for:))
            + settings.appTheming.values.custom.map(preview.target(for:))
        page.refresh(controller.appThemeEngine, targets: targets)
    }
}
