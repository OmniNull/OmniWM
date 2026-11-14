// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct WallpaperSchemeSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Environment(\.colorScheme) private var colorScheme
    @State private var problem: String?

    private var state: WallpaperPaletteState {
        controller.workspaceBarManager.wallpaperPaletteState
    }

    private var manager: WallpaperManager? {
        controller.wallpaperManager
    }

    var body: some View {
        Section("Colors") {
            Toggle("Match Colors to Wallpaper", isOn: Binding(
                get: { state.active },
                set: { on in
                    if on {
                        controller.workspaceBarManager.selectWallpaperScheme(state.scheme) { problem = $0 }
                    } else {
                        controller.workspaceBarManager.useStylePalette { problem = $0 }
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
                ForEach(ShellWallpaperScheme.allCases, id: \.self) { scheme in
                    schemeTile(scheme)
                }
            }
            .id("Color Scheme")
            .padding(.vertical, 4)
            if manager == nil {
                SettingsCaption(localized: "Previews of each scheme appear while Manage Wallpapers is on.")
            } else if manager?.paletteSwatches.isEmpty != false {
                SettingsCaption(localized: "Previews appear once OmniWM can read the main display’s wallpaper.")
            }
        }
        .id("Colors")
        .onAppear { manager?.showSwatches(true, for: .settings) }
        .onChange(of: manager.map(ObjectIdentifier.init)) { _, _ in manager?.showSwatches(true, for: .settings) }
        .onDisappear { manager?.showSwatches(false, for: .settings) }
        .alert("Colors", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(verbatim: problem ?? "")
        }
    }

    private func colors(_ scheme: ShellWallpaperScheme) -> [String] {
        guard let swatch = manager?.paletteSwatches.first(where: { $0.scheme == scheme.rawValue }) else { return [] }
        return colorScheme == .dark ? swatch.dark : swatch.light
    }

    private func schemeTile(_ scheme: ShellWallpaperScheme) -> some View {
        let selected = state.active && state.scheme == scheme
        let colors = colors(scheme)
        let title = ShellStyleText.paletteTitle(scheme.rawValue)
        return Button {
            controller.workspaceBarManager.selectWallpaperScheme(scheme) { problem = $0 }
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
