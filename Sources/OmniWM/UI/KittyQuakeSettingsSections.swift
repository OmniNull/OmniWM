// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct KittyQuakeSettingsSections: View {
    let quake: QuakeTerminalSettings
    let controller: WMController

    var body: some View {
        Group {
            placementSection
            behaviorSection
            appearanceSection
        }
    }

    private var placementSection: some View {
        Section("Kitty Placement") {
            QuakePlacementOverrideControls(
                title: "Override Kitty Placement",
                provider: .kitty,
                placement: Bindable(quake).kitty.placement
            )

            SettingsCaption(localized: "Placement changes apply the next time Kitty is shown.")

            SettingsCaption(
                localized: "Turning an override off returns that setting to Kitty's quick-access-terminal.conf the next time the Kitty panel starts."
            )
        }
        .id("Kitty Placement")
        .onChange(of: quake.kitty) { _, _ in
            controller.applyKittyQuakeSettings()
        }
    }

    private var behaviorSection: some View {
        Section("Kitty Behavior") {
            QuakeAutoHideOverridePicker(
                configTitle: "Kitty Config",
                provider: .kitty,
                autoHide: Bindable(quake).kitty.autoHide
            )
        }
        .id("Kitty Behavior")
    }

    private var appearanceSection: some View {
        Section("Kitty Appearance") {
            QuakeOpacityOverrideControls(
                title: "Override Kitty Opacity",
                provider: .kitty,
                opacity: Bindable(quake).kitty.opacity
            )

            if quake.kitty.opacity != nil {
                if controller.kittyQuickAccessTerminal.problem == .opacityNeedsRestart {
                    SettingsCaption(KittyQuickAccessTerminal.Problem.opacityNeedsRestart.message)
                }

                SettingsCaption(
                    localized: "Opacity changes apply live as you drag."
                )
            }
        }
        .id("Kitty Appearance")
    }
}
