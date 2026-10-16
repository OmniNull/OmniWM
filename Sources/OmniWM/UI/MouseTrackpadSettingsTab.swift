// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct MouseTrackpadSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var missionControlGestureProbe: MissionControlGestureProbe
    @Environment(SettingsNavigationModel.self) private var navigation
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    init(
        settings: SettingsStore,
        controller: WMController,
        missionControlGestureProbe: MissionControlGestureProbe = MissionControlGestureProbe()
    ) {
        self.settings = settings
        self.controller = controller
        _missionControlGestureProbe = State(initialValue: missionControlGestureProbe)
    }

    var body: some View {
        TabView(selection: Binding(
            get: { navigation.route.tab ?? "trackpad" },
            set: { navigation.selectTab($0) }
        )) {
            Tab("Trackpad", systemImage: "hand.draw", value: "trackpad") {
                Form {
                    TrackpadGesturesSettingsPanel(settings: settings, monitors: connectedMonitors)
                    macOSGestureSection
                }
                .formStyle(.grouped)
            }
            Tab("Mouse & Focus", systemImage: "computermouse", value: "mouse") {
                Form {
                    mouseMoveAndResizeSection
                    focusFollowsMouseSection
                }
                .formStyle(.grouped)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .onAppear(perform: missionControlGestureProbe.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            missionControlGestureProbe.refresh()
        }
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification))
        { _ in
            connectedMonitors = Monitor.current()
        }
    }

    private var macOSGestureSection: some View {
        Section("macOS Gestures") {
            SettingsCaption(
                localized: "macOS can also respond to the same fingers. Turn off matching gestures in System Settings → Trackpad → More Gestures if both actions fire."
            )
            if missionControlGestureProbe.status == .enabled {
                Label(
                    "Mission Control is enabled and may intercept matching upward swipes.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button("Open Trackpad Settings", action: missionControlGestureProbe.openTrackpadSettings)
                .id("Open Trackpad Settings")
                .accessibilityHint("Opens macOS Trackpad settings. Select More Gestures to review system gestures.")
        }
        .id("macOS Gestures")
    }

    private var mouseMoveAndResizeSection: some View {
        Section("Mouse Move & Resize") {
            Picker("Left Mouse Move Modifier", selection: Bindable(settings.gestures).mouseMoveModifierKey) {
                ForEach(MouseMoveModifierKey.allCases, id: \.self) { key in
                    Text(key.localizedDisplayName).tag(key)
                }
            }
            .id("Left Mouse Move Modifier")

            SettingsCaption(
                localized: "Hold this modifier and left-drag to swap tiled windows. Add Shift to insert into a Niri column or beside a Dwindle tile; choose Off to leave modified drags to apps."
            )

            Picker("Right Mouse Resize Modifier", selection: Bindable(settings.gestures).mouseResizeModifierKey) {
                ForEach(MouseResizeModifierKey.allCases, id: \.self) { key in
                    Text(key.localizedDisplayName).tag(key)
                }
            }
            .id("Right Mouse Resize Modifier")

            SettingsCaption(localized: "Hold this modifier combo + right mouse drag to resize tiled windows")
        }
        .id("Mouse Move & Resize")
    }

    private var focusFollowsMouseSection: some View {
        Section("Focus Follows Mouse") {
            Toggle("Enable Focus Follows Mouse", isOn: Bindable(settings.focus).followsMouse)
                .id("Enable Focus Follows Mouse")
                .onChange(of: settings.focus.followsMouse) { _, newValue in
                    controller.setFocusFollowsMouse(newValue)
                }

            Toggle("Raise Window When Focus Follows Mouse", isOn: Bindable(settings.focus).raiseOnMouseFocus)
                .id("Raise Window When Focus Follows Mouse")
                .disabled(!settings.focus.followsMouse)

            Picker("Focus Lock Modifier", selection: Bindable(settings.focus).lockModifier) {
                ForEach(FocusLockModifier.allCases, id: \.self) { key in
                    Text(key.localizedDisplayName).tag(key)
                }
            }
            .id("Focus Lock Modifier")
            .disabled(!settings.focus.followsMouse)

            SettingsCaption(
                localized: "Hold this modifier to move the cursor over other windows without changing focus."
            )
        }
        .id("Focus Follows Mouse")
    }
}
