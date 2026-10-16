// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

extension GlobalBarSettingsSection {
    var appearanceSection: some View {
        Section("Appearance") {
            SettingsSliderRow(
                label: String(localized: "Bar Thickness"),
                value: profileBinding("height", value: style?.settings.height ?? settings.workspaceBar.height),
                range: 20 ... 200,
                step: 2,
                valueText: String(localized: "\(Int(style?.settings.height ?? settings.workspaceBar.height)) pt")
            )

            SettingsSliderRow(
                label: String(localized: "Background Opacity"),
                value: profileBinding(
                    "backgroundOpacity",
                    value: style?.settings.backgroundOpacity ?? settings.workspaceBar.backgroundOpacity
                ),
                range: 0 ... 1,
                step: 0.05,
                valueText: "\(Int((style?.settings.backgroundOpacity ?? settings.workspaceBar.backgroundOpacity) * 100))%"
            )

            SettingsSliderRow(
                label: String(localized: "Inactive Icon Opacity"),
                value: profileBinding(
                    "inactiveIconOpacity",
                    value: style?.settings.inactiveIconOpacity ?? settings.workspaceBar.inactiveIconOpacity ?? 0.5
                ),
                range: 0 ... 1,
                step: 0.05,
                valueText: "\(Int((style?.settings.inactiveIconOpacity ?? settings.workspaceBar.inactiveIconOpacity ?? 0.5) * 100))%",
                resetAction: {
                    edit {
                        try await ShellSettingsEdits.set(
                            Optional<Double>.none,
                            key: "inactiveIconOpacity",
                            settings: settings,
                            controller: controller
                        )
                    }
                },
                resetHelp: String(localized: "Reset to Style Defaults")
            )
            .help("Opacity of app icons that are not focused")

            Toggle(
                "Transparent Background",
                isOn: profileBinding(
                    "transparentBackground",
                    value: style?.settings.transparentBackground ?? settings.workspaceBar.transparentBackground
                )
            )
            .help("Hide the workspace bar material, tint, and border while keeping its contents interactive.")

            Toggle(
                "Show Item Backgrounds",
                isOn: profileBinding(
                    "showItemBackgrounds",
                    value: style?.settings.showItemBackgrounds ?? settings.workspaceBar.showItemBackgrounds
                )
            )
            .help("Show material backgrounds behind workspace groups, floating windows, scratchpad, and stats.")

            Toggle(
                "Solid Black Background",
                isOn: profileBinding(
                    "solidBlackBackground",
                    value: style?.settings.solidBlackBackground ?? settings.workspaceBar.solidBlackBackground
                )
            )
            .help("Fill the workspace bar with fully opaque black, overriding the tint, material, and border.")

            Toggle(
                "Show Accent Highlights",
                isOn: profileBinding(
                    "showAccentHighlights",
                    value: style?.settings.showAccentHighlights ?? settings.workspaceBar.showAccentHighlights
                )
            )
            .help("Show the focused-workspace outline and focused-icon accent glow.")

            Toggle("Custom Accent Color", isOn: customAccentColorBinding)

            if style?.accentColor != nil {
                ColorPicker("Accent Color", selection: accentColorBinding, supportsOpacity: false)
            }

            Toggle("Custom Text Color", isOn: customTextColorBinding)

            if style?.textColor != nil {
                ColorPicker("Text Color", selection: textColorBinding, supportsOpacity: false)
            }
        }
    }

    private var customAccentColorBinding: Binding<Bool> {
        Binding(
            get: { style?.accentColor != nil },
            set: { enabled in setColor(enabled ? style?.accentColor ?? defaultAccentColor : nil, key: "accentColor") }
        )
    }

    private var customTextColorBinding: Binding<Bool> {
        Binding(
            get: { style?.textColor != nil },
            set: { enabled in setColor(enabled ? style?.textColor ?? defaultTextColor : nil, key: "textColor") }
        )
    }

    private var accentColorBinding: Binding<Color> {
        Binding(
            get: { (style?.accentColor ?? defaultAccentColor).swiftUIColor },
            set: { color in
                if let value = SettingsColor(color: color, preservesAlpha: false) { setColor(value, key: "accentColor")
                }
            }
        )
    }

    private var textColorBinding: Binding<Color> {
        Binding(
            get: { (style?.textColor ?? defaultTextColor).swiftUIColor },
            set: { color in
                if let value = SettingsColor(color: color, preservesAlpha: false) { setColor(value, key: "textColor") }
            }
        )
    }

    private var defaultAccentColor: SettingsColor {
        SettingsColor(nsColor: .controlAccentColor, preservesAlpha: false)
            ?? SettingsColor(red: 0, green: 0.4784313725, blue: 1, alpha: 1)
    }

    private var defaultTextColor: SettingsColor {
        SettingsColor(nsColor: .labelColor, preservesAlpha: false)
            ?? SettingsColor(red: 1, green: 1, blue: 1, alpha: 1)
    }

    private func setColor(_ color: SettingsColor?, key: String) {
        edit { try await ShellSettingsEdits.set(color, key: key, settings: settings, controller: controller) }
    }
}
