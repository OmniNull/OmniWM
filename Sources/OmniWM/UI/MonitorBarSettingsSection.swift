// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct MonitorBarSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor
    @State private var editError: String?
    var pane: WorkspaceBarSettingsPane = .behavior

    private var monitorSettings: MonitorBarSettings {
        MonitorSettingsStore
            .get(for: monitor, in: settings.workspaceBar.profileOverride?.monitorOverrides ?? []) ?? MonitorBarSettings(
                monitorName: monitor.name
            )
    }

    private func updateSetting(_ update: @escaping @MainActor (inout MonitorBarSettings) -> Void) {
        Task {
            do {
                try await ShellSettingsEdits.updateMonitor(
                    monitor,
                    settings: settings,
                    controller: controller,
                    change: update
                )
            } catch { editError = error.localizedDescription }
        }
    }

    var body: some View {
        let ms = monitorSettings
        let inherited = settings.workspaceBar.resolved(for: monitor, includingProfileMonitor: false)

        Group {
            if pane == .behavior {
                Section("Workspace Bar") {
                    OverridableToggle(
                        label: String(localized: "Enable Workspace Bar"),
                        value: ms.enabled,
                        globalValue: inherited.enabled,
                        onChange: { newValue in updateSetting { $0.enabled = newValue } },
                        onReset: { updateSetting { $0.enabled = nil } }
                    )

                    if !settings.workspaceBar.enabled {
                        Text("Display settings are saved while the global Workspace Bar is off.")
                            .foregroundStyle(.secondary)
                    }

                    OverridableToggle(
                        label: String(localized: "Show Workspace Labels"),
                        value: ms.showLabels,
                        globalValue: inherited.showLabels,
                        onChange: { newValue in updateSetting { $0.showLabels = newValue } },
                        onReset: { updateSetting { $0.showLabels = nil } }
                    )

                    OverridableToggle(
                        label: String(localized: "Show Floating Windows"),
                        value: ms.showFloatingWindows,
                        globalValue: inherited.showFloatingWindows,
                        onChange: { newValue in updateSetting { $0.showFloatingWindows = newValue } },
                        onReset: { updateSetting { $0.showFloatingWindows = nil } }
                    )

                    OverridableToggle(
                        label: String(localized: "Deduplicate App Icons"),
                        value: ms.deduplicateAppIcons,
                        globalValue: inherited.deduplicateAppIcons,
                        onChange: { newValue in updateSetting { $0.deduplicateAppIcons = newValue } },
                        onReset: { updateSetting { $0.deduplicateAppIcons = nil } }
                    )
                    .help("Group workspace windows by app with badge counts; scratchpad pills always group by app")

                    OverridableToggle(
                        label: String(localized: "Hide Empty Workspaces"),
                        value: ms.hideEmptyWorkspaces,
                        globalValue: inherited.hideEmptyWorkspaces,
                        onChange: { newValue in updateSetting { $0.hideEmptyWorkspaces = newValue } },
                        onReset: { updateSetting { $0.hideEmptyWorkspaces = nil } }
                    )

                    OverridableToggle(
                        label: String(localized: "Automatically hide and show the workspace bar"),
                        value: ms.autoHide,
                        globalValue: inherited.autoHide,
                        onChange: { newValue in updateSetting { $0.autoHide = newValue } },
                        onReset: { updateSetting { $0.autoHide = nil } }
                    )
                }
            }

            if pane == .layout {
                Section("Screen Placement") {
                    OverridableToggle(
                        label: String(localized: "Reserve Space for Workspace Bar"),
                        value: ms.reserveLayoutSpace,
                        globalValue: inherited.reserveLayoutSpace,
                        onChange: { newValue in updateSetting { $0.reserveLayoutSpace = newValue } },
                        onReset: { updateSetting { $0.reserveLayoutSpace = nil } }
                    )
                    .help(
                        "Reserve tiled layout space at the selected edge. Overlapping bars reserve only the portion below the menu bar."
                    )

                    if ms.fullWidth ?? inherited.fullWidth {
                        OverridablePicker(
                            label: String(localized: "Notch Mode"),
                            value: ms.fullWidthNotchMode,
                            globalValue: inherited.fullWidthNotchMode,
                            options: WorkspaceBarFullWidthNotchMode.allCases,
                            displayName: { $0.displayName },
                            onChange: { newValue in updateSetting { $0.fullWidthNotchMode = newValue } },
                            onReset: { updateSetting { $0.fullWidthNotchMode = nil } }
                        )
                        .help(
                            "Where the Center widgets go on a display with a notch: centered under it (Off), with the whole bar below the menu bar, beside the notch, or split around it, with the first half on its left. Notch modes are ignored at Bottom, Left, and Right."
                        )
                    } else {
                        OverridablePicker(
                            label: String(localized: "Notch Mode"),
                            value: ms.notchMode,
                            globalValue: inherited.notchMode,
                            options: WorkspaceBarNotchMode.allCases,
                            displayName: { $0.displayName },
                            onChange: { newValue in updateSetting { $0.notchMode = newValue } },
                            onReset: { updateSetting { $0.notchMode = nil } }
                        )
                        .help(
                            "Move below the menu bar, place it to the right of the notch (centered on displays without a notch), split around it, or fill the area to its left, covering application menus. Without a notch, Fill Left covers the left half of the menu bar. Notch modes are ignored at Bottom, Left, and Right."
                        )

                        OverridableSlider(
                            label: String(localized: "Active Zone Width"),
                            value: ms.notchActiveZoneWidth,
                            globalValue: inherited.notchActiveZoneWidth,
                            range: 100 ... 400,
                            step: 10,
                            formatter: { String(localized: "\(Int($0)) px") },
                            onChange: { newValue in updateSetting { $0.notchActiveZoneWidth = newValue } },
                            onReset: { updateSetting { $0.notchActiveZoneWidth = nil } }
                        )
                        .help("Width of the zone next to the notch that the focused workspace stays centered in")
                    }
                }

                Section("Position & Level") {
                    OverridablePicker(
                        label: String(localized: "Position"),
                        value: ms.position,
                        globalValue: inherited.position,
                        options: WorkspaceBarPosition.allCases,
                        displayName: { $0.displayName },
                        onChange: { newValue in updateSetting { $0.position = newValue } },
                        onReset: { updateSetting { $0.position = nil } }
                    )

                    OverridableToggle(
                        label: String(localized: "Full Width"),
                        value: ms.fullWidth,
                        globalValue: inherited.fullWidth,
                        onChange: { newValue in updateSetting { $0.fullWidth = newValue } },
                        onReset: { updateSetting { $0.fullWidth = nil } }
                    )
                    .help(
                        "Span the whole edge of the screen, with each widget group pinned to its start, center, or end"
                    )

                    OverridablePicker(
                        label: String(localized: "Window Level"),
                        value: ms.windowLevel,
                        globalValue: inherited.windowLevel,
                        options: WorkspaceBarWindowLevel.allCases,
                        displayName: { $0.displayName },
                        onChange: { newValue in updateSetting { $0.windowLevel = newValue } },
                        onReset: { updateSetting { $0.windowLevel = nil } }
                    )
                }

                Section("Position Offset") {
                    OverridableStepper(
                        label: String(localized: "X Offset"),
                        value: ms.xOffset,
                        globalValue: inherited.xOffset,
                        step: 10,
                        formatter: { String(localized: "\(Int($0)) px") },
                        onChange: { newValue in updateSetting { $0.xOffset = newValue } },
                        onReset: { updateSetting { $0.xOffset = nil } }
                    )
                    .help("Horizontal offset (negative = left, positive = right)")

                    OverridableStepper(
                        label: String(localized: "Y Offset"),
                        value: ms.yOffset,
                        globalValue: inherited.yOffset,
                        step: 10,
                        formatter: { String(localized: "\(Int($0)) px") },
                        onChange: { newValue in updateSetting { $0.yOffset = newValue } },
                        onReset: { updateSetting { $0.yOffset = nil } }
                    )
                    .help("Vertical offset (negative = down, positive = up)")
                }
            }
            if pane == .appearance {
                Section("Appearance") {
                    OverridableSlider(
                        label: String(localized: "Bar Thickness"),
                        value: ms.height,
                        globalValue: inherited.height,
                        range: 20 ... 200,
                        step: 2,
                        formatter: { String(localized: "\(Int($0)) pt") },
                        onChange: { newValue in updateSetting { $0.height = newValue } },
                        onReset: { updateSetting { $0.height = nil } }
                    )

                    OverridableSlider(
                        label: String(localized: "Background Opacity"),
                        value: ms.backgroundOpacity,
                        globalValue: inherited.backgroundOpacity,
                        range: 0 ... 1,
                        step: 0.05,
                        formatter: { "\(Int($0 * 100))%" },
                        onChange: { newValue in updateSetting { $0.backgroundOpacity = newValue } },
                        onReset: { updateSetting { $0.backgroundOpacity = nil } }
                    )

                    OverridableSlider(
                        label: String(localized: "Inactive Icon Opacity"),
                        value: ms.inactiveIconOpacity,
                        globalValue: inherited.inactiveIconOpacity ?? 0.5,
                        range: 0 ... 1,
                        step: 0.05,
                        formatter: { "\(Int($0 * 100))%" },
                        onChange: { newValue in updateSetting { $0.inactiveIconOpacity = newValue } },
                        onReset: { updateSetting { $0.inactiveIconOpacity = nil } }
                    )
                    .help("Opacity of app icons that are not focused")

                    OverridableToggle(
                        label: String(localized: "Transparent Background"),
                        value: ms.transparentBackground,
                        globalValue: inherited.transparentBackground,
                        onChange: { newValue in updateSetting { $0.transparentBackground = newValue } },
                        onReset: { updateSetting { $0.transparentBackground = nil } }
                    )
                    .help("Hide the workspace bar material, tint, and border while keeping its contents interactive.")

                    OverridableToggle(
                        label: String(localized: "Solid Black Background"),
                        value: ms.solidBlackBackground,
                        globalValue: inherited.solidBlackBackground,
                        onChange: { newValue in updateSetting { $0.solidBlackBackground = newValue } },
                        onReset: { updateSetting { $0.solidBlackBackground = nil } }
                    )
                    .help("Fill the workspace bar with fully opaque black, overriding the tint, material, and border.")

                    OverridableToggle(
                        label: String(localized: "Show Item Backgrounds"),
                        value: ms.showItemBackgrounds,
                        globalValue: inherited.showItemBackgrounds,
                        onChange: { newValue in updateSetting { $0.showItemBackgrounds = newValue } },
                        onReset: { updateSetting { $0.showItemBackgrounds = nil } }
                    )
                    .help("Show material backgrounds behind workspace groups, floating windows, scratchpad, and stats.")

                    OverridableToggle(
                        label: String(localized: "Show Accent Highlights"),
                        value: ms.showAccentHighlights,
                        globalValue: inherited.showAccentHighlights,
                        onChange: { newValue in updateSetting { $0.showAccentHighlights = newValue } },
                        onReset: { updateSetting { $0.showAccentHighlights = nil } }
                    )
                    .help("Show the focused-workspace outline and focused-icon accent glow.")
                }
            }
        }
        .shellSettingsError($editError)
    }
}
