// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

extension ShellDesktopBarInspector {
    var appearanceSection: some View {
        Section("Appearance") {
            slider(
                String(localized: "Bar Thickness"),
                key: "height",
                value: style?.settings.height ?? bar.height,
                range: 20 ... 200,
                step: 2,
                format: { String(localized: "\(Int($0)) pt") }
            )
            slider(
                String(localized: "Background Opacity"),
                key: "backgroundOpacity",
                value: style?.settings.backgroundOpacity ?? bar.backgroundOpacity,
                range: 0 ... 1,
                step: 0.05,
                format: { "\(Int($0 * 100))%" }
            )
            SettingsSliderRow(
                label: String(localized: "Inactive Icon Opacity"),
                value: binding(
                    "inactiveIconOpacity",
                    value: style?.settings.inactiveIconOpacity ?? bar.inactiveIconOpacity ?? 0.5,
                    continuous: true
                ),
                range: 0 ... 1, step: 0.05,
                valueText: "\(Int((editor.pending(editor.barTarget("inactiveIconOpacity"), as: Double.self) ?? style?.settings.inactiveIconOpacity ?? bar.inactiveIconOpacity ?? 0.5) * 100))%",
                resetAction: { editor.set(Optional<Double>.none, key: "inactiveIconOpacity") },
                resetHelp: String(localized: "Reset to Style Defaults")
            )
            .help("Opacity of app icons that are not focused")
            Toggle("Transparent Background", isOn: binding(
                "transparentBackground", value: style?.settings.transparentBackground ?? bar.transparentBackground
            ))
            .help("Hide the workspace bar material, tint, and border while keeping its contents interactive.")
            Toggle("Show Item Backgrounds", isOn: binding(
                "showItemBackgrounds", value: style?.settings.showItemBackgrounds ?? bar.showItemBackgrounds
            ))
            .help("Show material backgrounds behind workspace groups, floating windows, scratchpad, and stats.")
            Toggle("Solid Black Background", isOn: binding(
                "solidBlackBackground", value: style?.settings.solidBlackBackground ?? bar.solidBlackBackground
            ))
            .help("Fill the workspace bar with fully opaque black, overriding the tint, material, and border.")
            Toggle("Show Accent Highlights", isOn: binding(
                "showAccentHighlights", value: style?.settings.showAccentHighlights ?? bar.showAccentHighlights
            ))
            .help("Show the focused-workspace outline and focused-icon accent glow.")
            Toggle("Custom Accent Color", isOn: Binding(
                get: { style?.accentColor != nil },
                set: { editor.set($0 ? style?.accentColor ?? defaultAccentColor : nil, key: "accentColor") }
            ))
            if let color = style?.accentColor {
                ColorPicker(
                    "Accent Color",
                    selection: colorBinding("accentColor", value: color),
                    supportsOpacity: false
                )
            }
            Toggle("Custom Text Color", isOn: Binding(
                get: { style?.textColor != nil },
                set: { editor.set($0 ? style?.textColor ?? defaultTextColor : nil, key: "textColor") }
            ))
            if let color = style?.textColor {
                ColorPicker("Text Color", selection: colorBinding("textColor", value: color), supportsOpacity: false)
            }
        }
    }

    @ViewBuilder
    var effectsSection: some View {
        if let effect = editor.snapshot?.style.manifest?.barEffect {
            let shader = editor.snapshot?.config.barShader
            Section(effect.title) {
                SettingsCaption(localized: "This effect is shared by all displays in this style.")
                Toggle("Enable Background Effect", isOn: binding("enabled", value: shader != nil, table: "barShader"))
                if let shader {
                    let values = editor.shaderValues
                    ForEach(effect.values.indices.filter(values.indices.contains), id: \.self) { index in
                        ShellSettingsOptionRow(
                            key: "values", option: effect.values[index], value: .number(values[index])
                        ) { value in
                            if case let .number(number) = value { editor.setShaderValue(number, at: index) }
                        }
                    }
                    let fps = editor.pending(editor.barTarget("fps", table: "barShader"), as: Int.self) ?? shader.fps
                    SettingsSliderRow(
                        label: String(localized: "Frame Rate"),
                        value: Binding(
                            get: { Double(fps) },
                            set: { editor.set(Int($0), key: "fps", table: "barShader", continuous: true) }
                        ),
                        range: 0 ... 60, step: 1,
                        valueText: fps == 0 ? String(localized: "Still") : String(localized: "\(fps) fps")
                    )
                    SettingsCaption(
                        localized: "Lower frame rates reduce effect rendering. Zero keeps a still background."
                    )
                }
                Button("Reset Effect to Style Defaults") { editor.reset(table: "barShader") }
            }
        }
    }

    private var defaultAccentColor: SettingsColor {
        SettingsColor(nsColor: .controlAccentColor, preservesAlpha: false)
            ?? SettingsColor(red: 0, green: 0.4784313725, blue: 1, alpha: 1)
    }

    private var defaultTextColor: SettingsColor {
        SettingsColor(nsColor: .labelColor, preservesAlpha: false)
            ?? SettingsColor(red: 1, green: 1, blue: 1, alpha: 1)
    }

    private func colorBinding(_ key: String, value: SettingsColor) -> Binding<Color> {
        Binding(get: { value.swiftUIColor }, set: {
            if let color = SettingsColor(color: $0, preservesAlpha: false) { editor.set(color, key: key) }
        })
    }
}

struct ShellDesktopAllStyles: View {
    let editor: ShellDesktopEditor

    var body: some View {
        Section("All styles") {
            SettingsCaption(localized: "These controls apply to every style, including the active style.")
            Toggle("Enable Workspace Bar", isOn: Binding(get: { editor.barEnabled }, set: editor.setBarEnabled))
            Toggle("Show Dynamic Island", isOn: Binding(get: { editor.islandEnabled }, set: editor.setIslandEnabled))
                .disabled(editor.islandToggleDisabled)
            if !editor.barEnabled {
                SettingsCaption(localized: "Set up your bar now. It appears when you turn it on.")
            }
        }
        WorkspaceBarExcludedAppsSection(settings: editor.settings, controller: editor.controller)
        WorkspaceBarIconOverridesSection(settings: editor.settings, controller: editor.controller)
    }
}
