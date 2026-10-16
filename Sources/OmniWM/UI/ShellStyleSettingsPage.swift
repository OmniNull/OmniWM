// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct ShellStyleSettingsPage: View {
    @Bindable var settings: SettingsStore
    let controller: WMController
    @State private var selectedProfile: String?
    @State private var previewConfig: ShellConfig?
    @State private var editError: String?
    @State private var applying = false
    @State private var expanded = false

    private var configuration: ShellConfigurationCoordinator {
        controller.workspaceBarManager.shellConfiguration
    }

    private var previewProfile: String {
        selectedProfile ?? configuration.config.profile
    }

    var body: some View {
        SettingsPage(
            subtitle: String(
                localized: "Choose a look for your desktop. Preview a style, then use it when you are ready."
            )
        ) {
            Section("Styles") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    ForEach(configuration.profiles, id: \.self) { profile in
                        styleCard(profile)
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                if let config = previewConfig, config.profile == previewProfile {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Self.title(config.profile)).font(.headline)
                            Text(Self.description(config.profile)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if config.profile == configuration.config.profile {
                            Label("Active Style", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                        } else {
                            Button("Use Style") { use(config.profile) }
                                .buttonStyle(.borderedProminent)
                                .disabled(applying || configuration.isSaving)
                        }
                    }
                    ShellSettingsPreview(
                        config: config, style: ShellSettingsPreview.style(
                            settings: settings.workspaceBar,
                            config: config
                        ),
                        fullWidth: config.barOverride?.settings.fullWidth ?? settings.workspaceBar.fullWidth,
                        revision: configuration.revision
                    )
                    .frame(height: config.barOverride?.settings.position?.isVertical == true ? 260 : 130)
                    if let island = config.island {
                        LabeledContent("Dynamic Island", value: ShellBarLayout.title(of: island.root))
                        Picker("Island Preview", selection: $expanded) {
                            Text("Compact").tag(false)
                            Text("Expanded").tag(true)
                        }
                        .pickerStyle(.segmented)
                        ShellSettingsPreview(
                            config: config,
                            surface: .island(expanded: expanded),
                            revision: configuration.revision
                        )
                        .frame(height: expanded ? 250 : 110)
                    }
                    SettingsCaption(
                        localized: "Sample data. Your desktop uses live information and system material effects."
                    )
                    SettingsCaption(config.profile == configuration.config.profile
                        ? String(localized: "Changes to this style’s controls apply immediately.")
                        :
                        String(
                            localized: "Browsing previews leaves your active style unchanged. Use Style preserves settings saved for both styles."
                        ))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            } header: {
                Text("Preview")
            }
            Section("Palette") {
                LabeledContent("Active Style", value: Self.title(configuration.config.profile))
                Picker("Palette", selection: Binding(
                    get: { configuration.config.themeName },
                    set: { theme in perform { _ = try await configuration.selectTheme(theme) } }
                )) {
                    ForEach(configuration.themes, id: \.self) { theme in
                        Text(Self.paletteTitle(theme)).tag(theme)
                    }
                }
                if configuration.config.themeName == ShellWallpaperPalette.themeName {
                    Picker("Color Scheme", selection: Binding(
                        get: { configuration.config.wallpaperScheme },
                        set: { scheme in perform { _ = try await configuration.selectScheme(scheme) } }
                    )) {
                        ForEach(ShellWallpaperScheme.allCases, id: \.self) { scheme in
                            Text(Self.paletteTitle(scheme.rawValue)).tag(scheme)
                        }
                    }
                }
                SettingsCaption(localized: "Palettes change colors while keeping the style’s layout and widgets.")
            }
            .disabled(configuration.isSaving)
            Section("Display Surfaces") {
                Toggle("Show Workspace Bar", isOn: Binding(
                    get: { settings.workspaceBar.enabled }, set: { controller.setWorkspaceBarEnabled($0) }
                ))
                Toggle("Show Dynamic Island", isOn: Binding(
                    get: { settings.island.enabled },
                    set: { settings.island.enabled = $0
                        controller.updateWorkspaceBarSettings()
                    }
                ))
                .disabled(configuration.config.island == nil && !settings.island.enabled)
                SettingsCaption(
                    localized: "The bar and island have independent switches. System includes Focus Ribbon; Lake includes configurable island widgets."
                )
            }
        }
        .task {
            do { try await configuration.ensureLoaded() }
            catch { editError = error.localizedDescription }
        }
        .task(id: PreviewSelection(profile: previewProfile, revision: configuration.revision)) {
            let profile = previewProfile
            previewConfig = nil
            do {
                let config = try await configuration.previewConfig(profile: profile)
                try Task.checkCancellation()
                previewConfig = config
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                editError = error.localizedDescription
            }
        }
        .shellSettingsError($editError)
    }

    private struct PreviewSelection: Equatable {
        let profile: String
        let revision: UInt64
    }

    private func styleCard(_ profile: String) -> some View {
        Button {
            selectedProfile = profile
            expanded = false
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ShellStyleThumbnail(profile: profile, settings: settings.workspaceBar, configuration: configuration)
                    .frame(height: 55)
                HStack {
                    Text(Self.title(profile)).font(.headline)
                    Spacer()
                    if profile == configuration.config.profile {
                        Image(systemName: "checkmark.circle.fill")
                    }
                }
                Text(Self.description(profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, minHeight: 85, alignment: .topLeading)
            .padding(6)
        }
        .buttonStyle(.bordered)
        .overlay {
            if profile == previewProfile {
                RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 2)
            }
        }
    }

    private func use(_ profile: String) {
        applying = true
        Task {
            defer { applying = false }
            do { _ = try await configuration.selectProfile(profile) }
            catch { editError = error.localizedDescription }
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await operation() }
            catch { editError = error.localizedDescription }
        }
    }

    static func title(_ profile: String) -> String {
        profile == ShellDefaults.profile ? String(localized: "Default") : paletteTitle(profile)
    }

    static func paletteTitle(_ name: String) -> String {
        switch name {
        case "native": String(localized: "Follow macOS")
        case ShellWallpaperPalette.themeName: String(localized: "Wallpaper Colors")
        case "tonalSpot": String(localized: "Tonal Spot")
        case "fruitSalad": String(localized: "Fruit Salad")
        default: name.replacingOccurrences(of: "-", with: " ").localizedCapitalized
        }
    }

    static func description(_ profile: String) -> String {
        switch profile {
        case "default": String(localized: "A compact bar with workspace and app controls.")
        case "system": String(localized: "Familiar Mac controls with Focus Ribbon for window navigation.")
        case "lake": String(localized: "A minimal bar and a customizable island for media, calendar, and more.")
        case "celestial": String(localized: "A vertical bar with spacious app and workspace tiles.")
        case "nocturne": String(localized: "A rounded bar with rich status widgets and deep colors.")
        case "wayline": String(localized: "A structured bar with labeled workspaces and quick status controls.")
        case "matrix": String(localized: "A terminal-inspired bar with green accents and a rain shader.")
        case "sakura": String(localized: "A light bar with soft pink accents and a drifting-petal shader.")
        default: String(localized: "A custom style you added.")
        }
    }
}

private struct ShellStyleThumbnail: View {
    let profile: String
    let settings: WorkspaceBarSettings
    let configuration: ShellConfigurationCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var failure = false

    private struct Identity: Equatable {
        let profile: String
        let revision: UInt64
        let dark: Bool
        let scale: CGFloat
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFit()
            } else if failure {
                Image(systemName: "rectangle.topthird.inset.filled").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary, in: .rect(cornerRadius: 5))
        .clipped()
        .task(id: Identity(
            profile: profile,
            revision: configuration.revision,
            dark: colorScheme == .dark,
            scale: displayScale
        )) {
            image = nil
            failure = false
            do {
                let config = try await configuration.previewConfig(profile: profile)
                let request = ShellSettingsPreview.Request(
                    config: config, surface: .bar, style: ShellSettingsPreview.style(
                        settings: settings,
                        config: config
                    ),
                    scale: displayScale, dark: colorScheme == .dark,
                    fullWidth: config.barOverride?.settings.fullWidth ?? settings.fullWidth,
                    revision: configuration.revision
                )
                let rendered = try await ShellSettingsPreview.cachedImage(for: request)
                try Task.checkCancellation()
                image = rendered
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                failure = true
            }
        }
    }
}
