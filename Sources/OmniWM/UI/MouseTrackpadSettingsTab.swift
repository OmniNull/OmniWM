// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
                localized: "Hold this modifier and left-drag tiled windows. In Dwindle, drop at the center to swap, near a tile edge to insert beside it, or near a workspace edge to insert at the outer edge. In Niri, add Shift before starting the drag to insert into a column. Choose Off to leave modified drags to apps."
            )

            Picker("Right Mouse Resize Modifier", selection: Bindable(settings.gestures).mouseResizeModifierKey) {
                ForEach(MouseResizeModifierKey.allCases, id: \.self) { key in
                    Text(key.localizedDisplayName).tag(key)
                }
            }
            .id("Right Mouse Resize Modifier")

            SettingsCaption(localized: "Hold this modifier combo + right mouse drag to resize tiled windows")

            Picker("Resize Preview", selection: Bindable(settings.gestures).resizePreviewStyle) {
                ForEach(ResizePreviewStyle.allCases) { style in
                    Text(style.localizedDisplayName).tag(style)
                }
            }
            .id("Resize Preview")

            SettingsCaption(
                localized: "Applies to mouse resizing and to keyboard resizing in Niri. Window Snapshot stretches a still image of each moving window and needs Screen Recording. Glass Placeholder shows the app icon on glass and needs no permission. Windows get their final size once the resize ends."
            )
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

            SettingsSliderRow(
                label: String(localized: "Edge navigation interval"),
                value: Bindable(settings.focus).edgeNavigationInterval,
                range: FocusSettings.edgeNavigationIntervalRange,
                step: FocusSettings.edgeNavigationIntervalStep,
                valueText: String(
                    localized: "\(settings.focus.edgeNavigationInterval.formatted(.number.precision(.fractionLength(0 ... 2))))s"
                )
            )
            .id("Edge navigation interval")
            .disabled(!settings.focus.followsMouse)

            SettingsCaption(
                localized: "Hover at a Niri screen edge to move one column after this interval, then repeat while the pointer stays on the edge or preview. Move away to stop."
            )

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
