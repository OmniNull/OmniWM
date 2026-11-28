// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct QuakePlacementOverrideControls: View {
    let title: LocalizedStringKey
    let provider: QuakeTerminalProvider
    let placement: Binding<QuakePlacementOverride?>

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { [placement] in placement.wrappedValue != nil },
            set: { [placement] in placement.wrappedValue = $0 ? .defaultOverride : nil }
        ))
        .id("Override \(provider.displayName) Placement")
        .settingsField(provider == .kitty ? .quakeTerminalKittyPlacement : .quakeTerminalFootPlacement)

        if let current = placement.wrappedValue {
            Picker("Position", selection: Binding(
                get: { [placement] in placement.wrappedValue?.position ?? current.position },
                set: { [placement] in placement.wrappedValue?.position = $0 }
            )) {
                ForEach(QuakeTerminalPosition.allCases, id: \.self) { position in
                    Text(position.localizedDisplayName).tag(position)
                }
            }
            .id("\(provider.displayName) Position")
            .settingsField(provider == .kitty ? .quakeTerminalKittyPlacementPosition :
                .quakeTerminalFootPlacementPosition)

            SettingsSliderRow(
                field: .init(provider == .kitty ? .quakeTerminalKittyPlacementWidthPercent :
                    .quakeTerminalFootPlacementWidthPercent),
                label: String(localized: "Width"),
                value: Binding(
                    get: { [placement] in placement.wrappedValue?.widthPercent ?? current.widthPercent },
                    set: { [placement] in placement.wrappedValue?.widthPercent = $0 }
                ),
                range: 10 ... 100,
                step: 5,
                valueText: "\(Int(current.widthPercent))%"
            )
            .id("\(provider.displayName) Width")

            SettingsSliderRow(
                field: .init(provider == .kitty ? .quakeTerminalKittyPlacementHeightPercent :
                    .quakeTerminalFootPlacementHeightPercent),
                label: String(localized: "Height"),
                value: Binding(
                    get: { [placement] in placement.wrappedValue?.heightPercent ?? current.heightPercent },
                    set: { [placement] in placement.wrappedValue?.heightPercent = $0 }
                ),
                range: 10 ... 100,
                step: 5,
                valueText: "\(Int(current.heightPercent))%"
            )
            .id("\(provider.displayName) Height")
        }
    }
}

struct QuakeAutoHideOverridePicker: View {
    private enum Choice: Hashable {
        case config
        case on
        case off
    }

    let configTitle: LocalizedStringKey
    let provider: QuakeTerminalProvider
    let autoHide: Binding<Bool?>

    var body: some View {
        Picker("Auto-hide on Focus Loss", selection: Binding(
            get: { [autoHide] in
                switch autoHide.wrappedValue {
                case nil: Choice.config
                case true?: Choice.on
                case false?: Choice.off
                }
            },
            set: { [autoHide] choice in
                switch choice {
                case .config: autoHide.wrappedValue = nil
                case .on: autoHide.wrappedValue = true
                case .off: autoHide.wrappedValue = false
                }
            }
        )) {
            Text(configTitle).tag(Choice.config)
            Text("On").tag(Choice.on)
            Text("Off").tag(Choice.off)
        }
        .id("\(provider.displayName) Auto-hide on Focus Loss")
        .settingsField(provider == .kitty ? .quakeTerminalKittyAutoHide : .quakeTerminalFootAutoHide)
    }
}

struct QuakeOpacityOverrideControls: View {
    let title: LocalizedStringKey
    let provider: QuakeTerminalProvider
    let opacity: Binding<Double?>

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { [opacity] in opacity.wrappedValue != nil },
            set: { [opacity] in opacity.wrappedValue = $0 ? QuakeOpacityOverride.defaultOverride : nil }
        ))
        .id("Override \(provider.displayName) Opacity")
        .settingsField(provider == .kitty ? .quakeTerminalKittyOpacity : .quakeTerminalFootOpacity)

        if let current = opacity.wrappedValue {
            SettingsSliderRow(
                field: .init(provider == .kitty ? .quakeTerminalKittyOpacity : .quakeTerminalFootOpacity),
                label: String(localized: "Quake Background Opacity"),
                value: Binding(
                    get: { [opacity] in opacity.wrappedValue ?? current },
                    set: { [opacity] in opacity.wrappedValue = $0 }
                ),
                range: 0 ... 1.0,
                step: 0.05,
                valueText: "\(Int((current * 100).rounded()))%"
            )
            .id("\(provider.displayName) Background Opacity")
        }
    }
}
