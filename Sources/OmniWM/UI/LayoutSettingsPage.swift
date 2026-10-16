// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct LayoutSettingsPage: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Environment(SettingsNavigationModel.self) private var navigation

    private var selection: Binding<String> {
        Binding(get: { navigation.route.tab ?? "spacing" }, set: { navigation.selectTab($0) })
    }

    var body: some View {
        TabView(selection: selection) {
            Tab("Spacing", systemImage: "square.dashed", value: "spacing") {
                SpacingSettingsPage(settings: settings, controller: controller)
            }
            Tab("Niri", systemImage: "rectangle.split.3x1", value: "niri") {
                NiriSettingsTab(settings: settings, controller: controller)
            }
            Tab("Dwindle", systemImage: "square.split.2x2", value: "dwindle") {
                DwindleSettingsTab(settings: settings, controller: controller)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}
