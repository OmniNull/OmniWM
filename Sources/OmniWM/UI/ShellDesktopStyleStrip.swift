// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct ShellDesktopStyleStrip: View {
    let editor: ShellDesktopEditor
    @State private var gallery: ShellStyleGallery?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(editor.cards) { card in
                    Button {
                        Task { await editor.selectStyle(card.name) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            ShellDesktopStyleThumbnail(editor: editor, profile: card.name)
                                .frame(height: 38)
                            HStack(spacing: 4) {
                                Text(card.title).fontWeight(.medium)
                                Spacer(minLength: 0)
                                if card
                                    .active { Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary) }
                            }
                            .font(.caption)
                        }
                        .padding(8).frame(width: 132)
                        .background(.background.secondary, in: .rect(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    editor.selectedStyle == card.name ? Color.accentColor : .clear,
                                    lineWidth: 2
                                )
                        }
                    }
                    .buttonStyle(.plain).help(card.summary)
                }
                if let source = ShellStyleGallery.source {
                    Button { gallery = ShellStyleGallery(editor: editor, source: source) } label: {
                        Label("Get Styles", systemImage: "plus.circle").font(.caption.weight(.medium))
                            .frame(width: 132, height: 60)
                            .background(.background.secondary, in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .sheet(item: $gallery) { ShellStyleGalleryView(gallery: $0) }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .frame(height: 76)
    }
}

private struct ShellDesktopStyleThumbnail: View {
    let editor: ShellDesktopEditor
    let profile: String
    @State private var config: ShellConfig?
    @State private var failure: String?

    var body: some View {
        Group {
            if let config {
                ShellDesktopThumbnailImage(editor: editor, config: config)
                    .allowsHitTesting(false)
            } else if let failure {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).help(failure)
            } else {
                ProgressView().controlSize(.mini).frame(maxWidth: .infinity)
            }
        }
        .task(id: editor.configuration.revision) {
            do {
                let value = try await editor.configuration.previewConfig(profile: profile)
                try Task.checkCancellation()
                config = value
                failure = nil
            } catch is CancellationError {
            } catch {
                config = nil
                failure = error.localizedDescription
            }
        }
    }
}

private struct ShellDesktopThumbnailImage: View {
    let editor: ShellDesktopEditor
    let config: ShellConfig
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var failure: String?

    private var request: ShellSettingsPreview.Request {
        .init(
            config: config, surface: .bar,
            style: ShellSettingsPreview.style(settings: editor.settings.workspaceBar, config: config),
            scale: displayScale, dark: colorScheme == .dark,
            fullWidth: config.barOverride?.settings.fullWidth ?? editor.settings.workspaceBar.fullWidth,
            sourceGeneration: editor.configuration.sourceGeneration
        )
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable().scaledToFill()
                    .frame(width: request.style.vertical ? 32 : 116, height: 38, alignment: .topLeading)
                    .clipped()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let failure {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary).help(failure)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary, in: .rect(cornerRadius: 4))
        .task(id: request) {
            do {
                let rendered = try await ShellSettingsPreview.cachedImage(
                    for: request, slot: .init(id: "thumbnail-" + config.profile, priority: .thumbnail)
                )
                try Task.checkCancellation()
                image = rendered
                failure = nil
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                failure = (error as? ShellScriptFailure)?.message ?? error.localizedDescription
            }
        }
    }
}
