// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct CommandPaletteSettingsTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section("Unified Search") {
                Toggle("Enable Unified Search", isOn: Bindable(settings.commandPalette).unifiedSearch)
                SettingsCaption(
                    localized: "Open Command Palette searches several palette modes at once and shows up to three top hits above the results. Each mode’s own Command Palette shortcut still opens just that mode."
                )
            }

            Section("Searched Modes") {
                ForEach(orderedModes, id: \.self) { mode in
                    modeRow(mode)
                }
                .onMove { settings.commandPalette.moveSearchedModes(fromOffsets: $0, toOffset: $1) }
                SettingsCaption(
                    localized: "Results are grouped in this order. Menu reads the frontmost app’s menus each time the palette opens. Clipboard needs clipboard history."
                )
            }

            Section("Top Hits") {
                Button("Clear Pick History") {
                    settings.clearUnifiedSearchPickHistory()
                }
                SettingsCaption(
                    localized: "Top hits learn from the results you pick in unified search. Clipboard picks are never remembered."
                )
            }
        }
        .formStyle(.grouped)
    }

    private var orderedModes: [CommandPaletteMode] {
        let searched = settings.commandPalette.searchedModes
        return searched + CommandPaletteMode.allCases.filter { !searched.contains($0) }
    }

    private func modeRow(_ mode: CommandPaletteMode) -> some View {
        let searched = settings.commandPalette.searchedModes
        let index = searched.firstIndex(of: mode)
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { index != nil },
                set: { settings.commandPalette.setMode(mode, searched: $0) }
            )) {
                Label {
                    Text(mode.localizedDisplayName)
                } icon: {
                    CommandPaletteModeIcon(mode: mode, pointSize: 13)
                        .frame(width: 20)
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            Button {
                settings.commandPalette.moveSearchedMode(mode, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == nil || index == 0)
            .accessibilityLabel(String(localized: "Move \(mode.localizedDisplayName) Up"))
            Button {
                settings.commandPalette.moveSearchedMode(mode, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index.map { $0 == searched.count - 1 } ?? true)
            .accessibilityLabel(String(localized: "Move \(mode.localizedDisplayName) Down"))
        }
        .buttonStyle(.borderless)
    }
}
