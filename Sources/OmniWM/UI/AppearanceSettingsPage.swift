// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct AppearanceSettingsPage: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Bindable var windowCornerPreferences: GlobalWindowCornerPreferences
    @Environment(SettingsNavigationModel.self) private var navigation

    private var selection: Binding<String> {
        Binding(get: { navigation.route.tab ?? "app" }, set: { navigation.selectTab($0) })
    }

    var body: some View {
        TabView(selection: selection) {
            Tab("App & Motion", systemImage: "paintpalette", value: "app") {
                appAppearance
            }
            Tab("Window Borders", systemImage: "square.dashed", value: "borders") {
                BorderSettingsTab(settings: settings, controller: controller)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var appAppearance: some View {
        let animationsEnabled = Binding(
            get: { controller.motionPolicy.userAnimationsEnabled },
            set: { controller.setAnimationsEnabled($0) }
        )
        return Form {
            Section("Appearance") {
                Picker("App Appearance", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.localizedDisplayName).tag(mode)
                    }
                }
                .id("App Appearance")
                .onChange(of: settings.appearanceMode) { _, _ in
                    controller.applyCurrentAppearanceMode()
                }

                SettingsCaption(localized: "Follows macOS appearance or uses the selected light or dark appearance.")

                Toggle("Show app icons in tab rails", isOn: Binding(
                    get: { settings.tabRailAppIcons },
                    set: { controller.setTabRailAppIcons($0) }
                ))
                .id("Show app icons in tab rails")
                SettingsCaption(localized: "Replaces compact markers with app icons. Applies to Niri and Dwindle.")

                Toggle("Enable Animations", isOn: animationsEnabled)
                    .id("Enable Animations")
                    .disabled(controller.motionPolicy.systemReducesMotion)
                SettingsCaption(
                    controller.motionPolicy.systemReducesMotion
                        ? String(localized: "Off while macOS Reduce Motion is on.")
                        : String(localized: "Turns OmniWM-authored animations on or off live without relaunching.")
                )

                SettingsSliderRow(
                    label: String(localized: "Tiling Animation Speed"),
                    value: Binding(
                        get: { controller.motionPolicy.animationSpeed },
                        set: { controller.setAnimationSpeed($0) }
                    ),
                    range: AnimationSpeed.range,
                    step: 0.25,
                    valueText: String(
                        localized: "\(controller.motionPolicy.animationSpeed.formatted(.number.precision(.fractionLength(0 ... 2))))×"
                    ),
                    resetAction: { controller.setAnimationSpeed(SettingsExport.defaults().animationSpeed) }
                )
                .id("Tiling Animation Speed")
                .disabled(!controller.motionPolicy.animationsEnabled)
                SettingsCaption(
                    localized: "1× is the default. Higher values make window and workspace transitions faster."
                )

                AppWindowCornerSettings(preferences: windowCornerPreferences)
            }
            .id("Appearance")
        }
        .formStyle(.grouped)
    }
}
