// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct QuakeTerminalSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    private var blurValueText: String {
        settings.quakeTerminal.backgroundBlurRadius == QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius
            ? String(localized: "Off")
            : "\(settings.quakeTerminal.backgroundBlurRadius)"
    }

    var body: some View {
        Form {
            Section("Quake Terminal") {
                Toggle("Enable Quake Terminal", isOn: Bindable(settings.quakeTerminal).enabled)
                    .onChange(of: settings.quakeTerminal.enabled) { _, newValue in
                        controller.setQuakeTerminalEnabled(newValue)
                    }
            }

            if settings.quakeTerminal.enabled {
                Section("Position & Size") {
                    Picker("Position", selection: Bindable(settings.quakeTerminal).position) {
                        ForEach(QuakeTerminalPosition.allCases, id: \.self) { position in
                            Text(position.localizedDisplayName).tag(position)
                        }
                    }

                    Picker("Show On", selection: Bindable(settings.quakeTerminal).monitorMode) {
                        ForEach(QuakeTerminalMonitorMode.allCases, id: \.self) { mode in
                            Text(mode.localizedDisplayName).tag(mode)
                        }
                    }

                    SettingsSliderRow(
                        label: String(localized: "Width"),
                        value: Bindable(settings.quakeTerminal).widthPercent,
                        range: 10 ... 100,
                        step: 5,
                        valueText: "\(Int(settings.quakeTerminal.widthPercent))%"
                    )

                    SettingsSliderRow(
                        label: String(localized: "Height"),
                        value: Bindable(settings.quakeTerminal).heightPercent,
                        range: 10 ... 100,
                        step: 5,
                        valueText: "\(Int(settings.quakeTerminal.heightPercent))%"
                    )

                    if settings.quakeTerminalUseCustomFrame {
                        Button("Reset to Default Position") {
                            settings.resetQuakeTerminalCustomFrame()
                        }
                    }
                }

                Section("Appearance") {
                    Picker("Background Effect", selection: Bindable(settings.quakeTerminal).backgroundEffect) {
                        ForEach(QuakeTerminalBackgroundEffect.allCases, id: \.self) { effect in
                            Text(effect.localizedDisplayName).tag(effect)
                        }
                    }
                    .onChange(of: settings.quakeTerminal.backgroundEffect) { _, _ in
                        controller.reloadQuakeTerminalBackgroundEffect()
                    }

                    SettingsSliderRow(
                        label: String(localized: "Quake Background Opacity"),
                        value: Bindable(settings.quakeTerminal).opacity,
                        range: 0.1 ... 1.0,
                        step: 0.05,
                        valueText: "\(Int(settings.quakeTerminal.opacity * 100))%"
                    )
                    .onChange(of: settings.quakeTerminal.opacity) { _, _ in
                        controller.reloadQuakeTerminalOpacity()
                    }

                    SettingsSliderRow(
                        label: String(localized: "Background Blur"),
                        value: Binding(
                            get: { [settings] in Double(settings.quakeTerminal.backgroundBlurRadius) },
                            set: { [settings] in settings.quakeTerminal.backgroundBlurRadius = Int($0.rounded()) }
                        ),
                        range: Double(QuakeTerminalAppearancePolicy.minimumBackgroundBlurRadius)
                            ... Double(QuakeTerminalAppearancePolicy.maximumBackgroundBlurRadius),
                        step: 5,
                        valueText: blurValueText
                    )
                    .onChange(of: settings.quakeTerminal.backgroundBlurRadius) { _, _ in
                        controller.reloadQuakeTerminalBackgroundBlur()
                    }
                    .disabled(settings.quakeTerminal.backgroundEffect != .standardBlur)

                    if settings.quakeTerminal.backgroundEffect != .standardBlur {
                        SettingsCaption(
                            localized: "The saved Standard Blur radius is preserved and becomes active again when Standard Blur is selected."
                        )
                    } else if QuakeTerminalAppearancePolicy.backgroundBlurIsHiddenByOpaqueBackground(
                        radius: settings.quakeTerminal.backgroundBlurRadius,
                        opacity: settings.quakeTerminal.opacity
                    ) {
                        SettingsCaption(
                            localized: "Blur only shows through a translucent terminal - lower the opacity to see it."
                        )
                    }
                }

                Section("Behavior") {
                    SettingsSliderRow(
                        label: String(localized: "Animation Duration"),
                        value: Bindable(settings.quakeTerminal).animationDuration,
                        range: 0 ... 1,
                        step: 0.1,
                        valueText: String(
                            localized: "\(settings.quakeTerminal.animationDuration.formatted(.number.precision(.fractionLength(1))))s"
                        )
                    )
                    .disabled(!controller.motionPolicy.animationsEnabled)

                    if !controller.motionPolicy.animationsEnabled {
                        SettingsCaption(localized: "Ignored while global animations are disabled.")
                    }

                    Toggle("Auto-hide on Focus Loss", isOn: Bindable(settings.quakeTerminal).autoHide)
                }
            }

            Section("About") {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsCaption(
                        localized: "Quake Terminal provides a drop-down terminal that can be toggled with a hotkey, similar to the console in Quake-style games."
                    )

                    Label("Default hotkey: Option + ` (backtick)", systemImage: "keyboard")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Label("Configure hotkey in Hotkeys settings", systemImage: "gearshape")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
