// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
                    .id("Enable Quake Terminal")
                    .settingsField(.quakeTerminalEnabled)
                    .onChange(of: settings.quakeTerminal.enabled) { _, newValue in
                        controller.setQuakeTerminalEnabled(newValue)
                    }

                Picker("Terminal", selection: Bindable(settings.quakeTerminal).provider) {
                    ForEach(QuakeTerminalProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .id("Terminal")
                .settingsField(.quakeTerminalProvider)
                .onChange(of: settings.quakeTerminal.provider) { _, newValue in
                    controller.setQuakeTerminalProvider(newValue)
                }

                if settings.quakeTerminal.provider == .kitty {
                    SettingsCaption(
                        localized: "Kitty's quick-access-terminal.conf controls tabs, splits, fonts and anything not overridden below. Overrides apply only to OmniWM's Kitty Quake panel."
                    )
                    if settings.quakeTerminal.kitty.placement == nil {
                        SettingsCaption(
                            localized: "OmniWM reserves space for the OmniShell top bar. Increase Kitty's configured lines for more terminal rows."
                        )
                    }
                    if let problem = controller.kittyQuickAccessTerminal.problem, problem != .opacityNeedsRestart {
                        SettingsCaption(problem.message)
                    }
                }
                if settings.quakeTerminal.provider == .foot {
                    SettingsCaption(
                        localized: "foot's own configuration controls fonts, colors and anything not overridden below. OmniWM runs a dedicated foot server for this panel. Tabs and splits are not available with foot."
                    )
                    SettingsCaption(
                        localized: "When the regular foot app is running, its own Option + ` (backtick) hotkey can clash with this shortcut. Change one of them, or set macos-quake-hotkey=none in foot.ini and restart foot."
                    )
                    if let problem = controller.footQuickAccessTerminal.problem {
                        SettingsCaption(problem.message)
                        if problem.needsSupportedApp,
                           let project = URL(string: "https://github.com/gobijan/foot-macos")
                        {
                            Link("Get foot for macOS", destination: project)
                                .font(.footnote)
                        }
                    }
                }
            }
            .id("Quake Terminal")

            if settings.quakeTerminal.enabled, settings.quakeTerminal.provider == .kitty {
                KittyQuakeSettingsSections(quake: settings.quakeTerminal, controller: controller)
            }

            if settings.quakeTerminal.enabled, settings.quakeTerminal.provider == .foot {
                FootQuakeSettingsSections(
                    quake: settings.quakeTerminal,
                    animationsEnabled: controller.motionPolicy.animationsEnabled
                )
            }

            if settings.quakeTerminal.enabled, settings.quakeTerminal.provider == .ghostty {
                Section("Position & Size") {
                    Picker("Position", selection: Bindable(settings.quakeTerminal).position) {
                        ForEach(QuakeTerminalPosition.allCases, id: \.self) { position in
                            Text(position.localizedDisplayName).tag(position)
                        }
                    }
                    .id("Position")
                    .settingsField(.quakeTerminalPosition)

                    Picker("Show On", selection: Bindable(settings.quakeTerminal).monitorMode) {
                        ForEach(QuakeTerminalMonitorMode.allCases, id: \.self) { mode in
                            Text(mode.localizedDisplayName).tag(mode)
                        }
                    }
                    .id("Show On")
                    .settingsField(.quakeTerminalMonitorMode)

                    SettingsSliderRow(
                        field: .init(.quakeTerminalWidthPercent),
                        label: String(localized: "Width"),
                        value: Bindable(settings.quakeTerminal).widthPercent,
                        range: 10 ... 100,
                        step: 5,
                        valueText: "\(Int(settings.quakeTerminal.widthPercent))%"
                    )
                    .id("Width")

                    SettingsSliderRow(
                        field: .init(.quakeTerminalHeightPercent),
                        label: String(localized: "Height"),
                        value: Bindable(settings.quakeTerminal).heightPercent,
                        range: 10 ... 100,
                        step: 5,
                        valueText: "\(Int(settings.quakeTerminal.heightPercent))%"
                    )
                    .id("Height")

                    if settings.quakeTerminalUseCustomFrame {
                        Button("Reset to Default Position") {
                            settings.resetQuakeTerminalCustomFrame()
                        }
                        .id("Reset to Default Position")
                    }
                }
                .id("Position & Size")

                Section("Appearance") {
                    Picker("Background Effect", selection: Bindable(settings.quakeTerminal).backgroundEffect) {
                        ForEach(QuakeTerminalBackgroundEffect.allCases, id: \.self) { effect in
                            Text(effect.localizedDisplayName).tag(effect)
                        }
                    }
                    .id("Background Effect")
                    .settingsField(.quakeTerminalBackgroundEffect)
                    .onChange(of: settings.quakeTerminal.backgroundEffect) { _, _ in
                        controller.reloadQuakeTerminalBackgroundEffect()
                    }

                    SettingsSliderRow(
                        field: .init(.quakeTerminalOpacity),
                        label: String(localized: "Quake Background Opacity"),
                        value: Bindable(settings.quakeTerminal).opacity,
                        range: 0.1 ... 1.0,
                        step: 0.05,
                        valueText: "\(Int(settings.quakeTerminal.opacity * 100))%"
                    )
                    .id("Quake Background Opacity")
                    .onChange(of: settings.quakeTerminal.opacity) { _, _ in
                        controller.reloadQuakeTerminalOpacity()
                    }

                    SettingsSliderRow(
                        field: .init(.quakeTerminalBackgroundBlurRadius),
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
                    .id("Background Blur")
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
                .id("Appearance")

                Section("Behavior") {
                    QuakeAnimationDurationRow(
                        quake: settings.quakeTerminal,
                        animationsEnabled: controller.motionPolicy.animationsEnabled
                    )

                    Toggle("Auto-hide on Focus Loss", isOn: Bindable(settings.quakeTerminal).autoHide)
                        .id("Auto-hide on Focus Loss")
                        .settingsField(.quakeTerminalAutoHide)
                }
                .id("Behavior")
            }

            Section("About") {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsCaption(
                        localized: "Quake Terminal provides a drop-down terminal that can be toggled with a hotkey, similar to the console in Quake-style games."
                    )

                    Label("Default hotkey: Option + ` (backtick)", systemImage: "keyboard")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    if settings.quakeTerminal.provider == .ghostty {
                        SettingsCaption(
                            localized: "Customize terminal tab and pane shortcuts in ~/.config/ghostty/config.ghostty. Reload with Cmd + Shift + , or relaunch OmniWM."
                        )
                    }

                    Label("Configure hotkey in Hotkeys settings", systemImage: "gearshape")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .id("About")
        }
        .formStyle(.grouped)
    }
}

struct QuakeAnimationDurationRow: View {
    let quake: QuakeTerminalSettings
    let animationsEnabled: Bool

    var body: some View {
        SettingsSliderRow(
            field: .init(.quakeTerminalAnimationDuration),
            label: String(localized: "Animation Duration"),
            value: Bindable(quake).animationDuration,
            range: 0 ... 1,
            step: 0.1,
            valueText: String(
                localized: "\(quake.animationDuration.formatted(.number.precision(.fractionLength(1))))s"
            )
        )
        .id("Animation Duration")
        .disabled(!animationsEnabled)

        if !animationsEnabled {
            SettingsCaption(localized: "Ignored while global animations are disabled.")
        }
    }
}
