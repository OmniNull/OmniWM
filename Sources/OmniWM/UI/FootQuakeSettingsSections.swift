// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct FootQuakeSettingsSections: View {
    let quake: QuakeTerminalSettings
    let animationsEnabled: Bool

    var body: some View {
        Group {
            Section("foot Placement") {
                QuakePlacementOverrideControls(
                    title: "Override foot Placement",
                    provider: .foot,
                    placement: Bindable(quake).foot.placement
                )

                SettingsCaption(localized: "Changes apply the next time foot is shown.")

                SettingsCaption(
                    localized: "Turning an override off returns that setting to foot.ini as loaded when OmniWM started foot's server."
                )
            }
            .id("foot Placement")

            Section("foot Behavior") {
                QuakeAnimationDurationRow(quake: quake, animationsEnabled: animationsEnabled)

                QuakeAutoHideOverridePicker(
                    configTitle: "foot Config",
                    provider: .foot,
                    autoHide: Bindable(quake).foot.autoHide
                )
            }
            .id("foot Behavior")

            Section("foot Appearance") {
                QuakeOpacityOverrideControls(
                    title: "Override foot Opacity",
                    provider: .foot,
                    opacity: Bindable(quake).foot.opacity
                )

                SettingsSliderRow(
                    field: .init(.quakeTerminalFootDim),
                    label: String(localized: "Dim Screen"),
                    value: Bindable(quake).foot.dim,
                    range: 0 ... 1,
                    step: 0.05,
                    valueText: quake.foot.dim == 0
                        ? String(localized: "Off")
                        : "\(Int((quake.foot.dim * 100).rounded()))%"
                )
                .id("Dim Screen")

                SettingsCaption(
                    localized: "Darkens the rest of the screen while foot's Quake terminal has keyboard focus."
                )
            }
            .id("foot Appearance")
        }
    }
}
