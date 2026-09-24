// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct WorkspaceBarSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    var body: some View {
        Form {
            MonitorScopeSection(
                selectedMonitor: $selectedMonitor,
                monitors: connectedMonitors,
                hasOverrides: { settings.workspaceBar.settings(for: $0) != nil },
                reset: { monitor in
                    settings.workspaceBar.remove(for: monitor)
                    controller.updateWorkspaceBarSettings()
                }
            )

            if let monitorId = selectedMonitor,
               let monitor = connectedMonitors.first(where: { $0.id == monitorId })
            {
                MonitorBarSettingsSection(
                    settings: settings,
                    controller: controller,
                    monitor: monitor
                )
            } else {
                GlobalBarSettingsSection(
                    settings: settings,
                    controller: controller
                )
            }

            WorkspaceBarExcludedAppsSection(
                settings: settings,
                controller: controller
            )

            WorkspaceBarIconOverridesSection(
                settings: settings,
                controller: controller
            )
        }
        .formStyle(.grouped)
        .onAppear {
            connectedMonitors = Monitor.current()
        }
    }
}

private struct GlobalBarSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var pendingAppearanceSync: Task<Void, Never>?

    var body: some View {
        Section("Workspace Bar") {
            Toggle("Enable Workspace Bar", isOn: Bindable(settings.workspaceBar).enabled)
                .onChange(of: settings.workspaceBar.enabled) { _, newValue in
                    controller.setWorkspaceBarEnabled(newValue)
                }

            if settings.workspaceBar.enabled {
                Toggle("Show Workspace Labels", isOn: Bindable(settings.workspaceBar).showLabels)
                    .onChange(of: settings.workspaceBar.showLabels) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }

                Toggle("Show Floating Windows", isOn: Bindable(settings.workspaceBar).showFloatingWindows)
                    .onChange(of: settings.workspaceBar.showFloatingWindows) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }

                Toggle("Deduplicate App Icons", isOn: Bindable(settings.workspaceBar).deduplicateAppIcons)
                    .onChange(of: settings.workspaceBar.deduplicateAppIcons) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                    .help("Group workspace windows by app with badge counts; scratchpad pills always group by app")

                Toggle("Hide Empty Workspaces", isOn: Bindable(settings.workspaceBar).hideEmptyWorkspaces)
                    .onChange(of: settings.workspaceBar.hideEmptyWorkspaces) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }

                Toggle("Reserve Space for Workspace Bar", isOn: Bindable(settings.workspaceBar).reserveLayoutSpace)
                    .onChange(of: settings.workspaceBar.reserveLayoutSpace) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                    .help(
                        "Reserve tiled layout space using the configured workspace bar height."
                    )

                Picker("Reveal on Modifier Hold", selection: Bindable(settings.workspaceBar).revealModifier) {
                    ForEach(WorkspaceBarRevealModifier.allCases, id: \.self) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .onChange(of: settings.workspaceBar.revealModifier) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }
                .help("Show the workspace bar as an overlay only while the selected modifiers are held")

                if settings.workspaceBar.revealModifier != .off {
                    SettingsSliderRow(
                        label: "Reveal Hold Delay",
                        value: Bindable(settings.workspaceBar).revealHoldMilliseconds,
                        range: 0 ... 1000,
                        step: 50,
                        valueText: "\(Int(settings.workspaceBar.revealHoldMilliseconds)) ms"
                    )
                    .onChange(of: settings.workspaceBar.revealHoldMilliseconds) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                }

                Toggle("Hide in Native Fullscreen", isOn: Bindable(settings.workspaceBar).hideInNativeFullscreen)
                    .onChange(of: settings.workspaceBar.hideInNativeFullscreen) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                    .help(
                        "Hide the bar on a monitor while it shows a native fullscreen window"
                    )

                Toggle("System Stats Button", isOn: Bindable(settings.workspaceBar).systemStatsButton)
                    .onChange(of: settings.workspaceBar.systemStatsButton) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                    .help("Show a small workspace bar button that opens a system stats popup")

                Picker("Notch Mode", selection: Bindable(settings.workspaceBar).notchMode) {
                    ForEach(WorkspaceBarNotchMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: settings.workspaceBar.notchMode) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }
                .help(
                    "Move below the notch, place it to the right (centered on displays without a notch), "
                        + "split around it, or fill the area to its left, covering application menus. "
                        + "Without a notch, Fill Left covers the left half of the menu bar."
                )

                if settings.workspaceBar.notchMode.isSplit {
                    SettingsSliderRow(
                        label: "Active Zone Width",
                        value: Bindable(settings.workspaceBar).notchActiveZoneWidth,
                        range: 100 ... 400,
                        step: 10,
                        valueText: "\(Int(settings.workspaceBar.notchActiveZoneWidth)) px"
                    )
                    .onChange(of: settings.workspaceBar.notchActiveZoneWidth) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }
                    .help("Width of the zone next to the notch that the focused workspace stays centered in")
                }
            }
        }

        if settings.workspaceBar.enabled {
            Section("Position & Level") {
                Picker("Position", selection: Bindable(settings.workspaceBar).position) {
                    ForEach(WorkspaceBarPosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .onChange(of: settings.workspaceBar.position) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }

                Picker("Window Level", selection: Bindable(settings.workspaceBar).windowLevel) {
                    ForEach(WorkspaceBarWindowLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .onChange(of: settings.workspaceBar.windowLevel) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }
            }

            Section("Position Offset") {
                SettingsNumberStepperRow(
                    label: "X Offset",
                    value: Bindable(settings.workspaceBar).xOffset,
                    step: 10,
                    valueText: "\(Int(settings.workspaceBar.xOffset)) px"
                )
                .help("Horizontal offset (negative = left, positive = right)")
                .onChange(of: settings.workspaceBar.xOffset) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }

                SettingsNumberStepperRow(
                    label: "Y Offset",
                    value: Bindable(settings.workspaceBar).yOffset,
                    step: 10,
                    valueText: "\(Int(settings.workspaceBar.yOffset)) px"
                )
                .help("Vertical offset (negative = down, positive = up)")
                .onChange(of: settings.workspaceBar.yOffset) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }
            }

            Section("Appearance") {
                SettingsSliderRow(
                    label: "Bar Height",
                    value: Bindable(settings.workspaceBar).height,
                    range: 20 ... 40,
                    step: 2,
                    valueText: "\(Int(settings.workspaceBar.height)) px"
                )
                .onChange(of: settings.workspaceBar.height) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }

                SettingsSliderRow(
                    label: "Background Opacity",
                    value: Bindable(settings.workspaceBar).backgroundOpacity,
                    range: 0 ... 0.5,
                    step: 0.05,
                    valueText: "\(Int(settings.workspaceBar.backgroundOpacity * 100))%"
                )
                .onChange(of: settings.workspaceBar.backgroundOpacity) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }

                SettingsSliderRow(
                    label: "Inactive Icon Opacity",
                    value: Binding(
                        get: { settings.workspaceBar.inactiveIconOpacity ?? 0.5 },
                        set: { settings.workspaceBar.inactiveIconOpacity = $0 }
                    ),
                    range: 0 ... 1,
                    step: 0.05,
                    valueText: "\(Int((settings.workspaceBar.inactiveIconOpacity ?? 0.5) * 100))%",
                    resetAction: { settings.workspaceBar.inactiveIconOpacity = nil },
                    resetHelp: "Reset to System Default"
                )
                .onChange(of: settings.workspaceBar.inactiveIconOpacity) { _, _ in
                    controller.updateWorkspaceBarSettings()
                }
                .help("Opacity of app icons that are not focused")

                Toggle("Transparent Background", isOn: Bindable(settings.workspaceBar).transparentBackground)
                    .help("Hide the workspace bar material, tint, and border while keeping its contents interactive.")
                    .onChange(of: settings.workspaceBar.transparentBackground) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }

                Toggle("Show Item Backgrounds", isOn: Bindable(settings.workspaceBar).showItemBackgrounds)
                    .help("Show material backgrounds behind workspace groups, floating windows, scratchpad, and stats.")
                    .onChange(of: settings.workspaceBar.showItemBackgrounds) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }

                Toggle("Solid Black Background", isOn: Bindable(settings.workspaceBar).solidBlackBackground)
                    .help("Fill the workspace bar with fully opaque black, overriding the tint, material, and border.")
                    .onChange(of: settings.workspaceBar.solidBlackBackground) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }

                Toggle("Show Accent Highlights", isOn: Bindable(settings.workspaceBar).showAccentHighlights)
                    .help("Show the focused-workspace outline and focused-icon accent glow.")
                    .onChange(of: settings.workspaceBar.showAccentHighlights) { _, _ in
                        controller.updateWorkspaceBarSettings()
                    }

                Toggle("Custom Accent Color", isOn: customAccentColorBinding)

                if settings.workspaceBar.accentColor != nil {
                    ColorPicker("Accent Color", selection: accentColorBinding, supportsOpacity: false)
                }

                Toggle("Custom Text Color", isOn: customTextColorBinding)

                if settings.workspaceBar.textColor != nil {
                    ColorPicker("Text Color", selection: textColorBinding, supportsOpacity: false)
                }
            }
        }
    }

    private var customAccentColorBinding: Binding<Bool> {
        Binding(
            get: { settings.workspaceBar.accentColor != nil },
            set: { enabled in
                settings.workspaceBar.accentColor = enabled ? settings
                    .workspaceBar.accentColor ?? defaultAccentColor : nil
                debouncedAppearanceSync()
            }
        )
    }

    private var customTextColorBinding: Binding<Bool> {
        Binding(
            get: { settings.workspaceBar.textColor != nil },
            set: { enabled in
                settings.workspaceBar.textColor = enabled ? settings.workspaceBar.textColor ?? defaultTextColor : nil
                debouncedAppearanceSync()
            }
        )
    }

    private var accentColorBinding: Binding<Color> {
        Binding(
            get: { (settings.workspaceBar.accentColor ?? defaultAccentColor).swiftUIColor },
            set: { newColor in
                if let color = SettingsColor(color: newColor, preservesAlpha: false) {
                    settings.workspaceBar.accentColor = color
                    debouncedAppearanceSync()
                }
            }
        )
    }

    private var textColorBinding: Binding<Color> {
        Binding(
            get: { (settings.workspaceBar.textColor ?? defaultTextColor).swiftUIColor },
            set: { newColor in
                if let color = SettingsColor(color: newColor, preservesAlpha: false) {
                    settings.workspaceBar.textColor = color
                    debouncedAppearanceSync()
                }
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

    private func debouncedAppearanceSync() {
        pendingAppearanceSync?.cancel()
        pendingAppearanceSync = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            controller.updateWorkspaceBarAppearance()
        }
    }
}
