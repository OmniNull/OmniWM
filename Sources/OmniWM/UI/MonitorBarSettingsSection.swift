// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct MonitorBarSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor

    private var monitorSettings: MonitorBarSettings {
        settings.workspaceBar.settings(for: monitor) ?? MonitorBarSettings(
            monitorName: monitor.name
        )
    }

    private func updateSetting(_ update: (inout MonitorBarSettings) -> Void) {
        var ms = monitorSettings
        update(&ms)
        settings.workspaceBar.update(ms, for: monitor)
        controller.updateWorkspaceBarSettings()
    }

    var body: some View {
        let ms = monitorSettings

        Section("Workspace Bar") {
            OverridableToggle(
                label: String(localized: "Enable Workspace Bar"),
                value: ms.enabled,
                globalValue: settings.workspaceBar.enabled,
                onChange: { newValue in updateSetting { $0.enabled = newValue } },
                onReset: { updateSetting { $0.enabled = nil } }
            )

            OverridableToggle(
                label: String(localized: "Show Workspace Labels"),
                value: ms.showLabels,
                globalValue: settings.workspaceBar.showLabels,
                onChange: { newValue in updateSetting { $0.showLabels = newValue } },
                onReset: { updateSetting { $0.showLabels = nil } }
            )

            OverridableToggle(
                label: String(localized: "Show Floating Windows"),
                value: ms.showFloatingWindows,
                globalValue: settings.workspaceBar.showFloatingWindows,
                onChange: { newValue in updateSetting { $0.showFloatingWindows = newValue } },
                onReset: { updateSetting { $0.showFloatingWindows = nil } }
            )

            OverridableToggle(
                label: String(localized: "Deduplicate App Icons"),
                value: ms.deduplicateAppIcons,
                globalValue: settings.workspaceBar.deduplicateAppIcons,
                onChange: { newValue in updateSetting { $0.deduplicateAppIcons = newValue } },
                onReset: { updateSetting { $0.deduplicateAppIcons = nil } }
            )
            .help("Group workspace windows by app with badge counts; scratchpad pills always group by app")

            OverridableToggle(
                label: String(localized: "Hide Empty Workspaces"),
                value: ms.hideEmptyWorkspaces,
                globalValue: settings.workspaceBar.hideEmptyWorkspaces,
                onChange: { newValue in updateSetting { $0.hideEmptyWorkspaces = newValue } },
                onReset: { updateSetting { $0.hideEmptyWorkspaces = nil } }
            )

            OverridableToggle(
                label: String(localized: "Reserve Space for Workspace Bar"),
                value: ms.reserveLayoutSpace,
                globalValue: settings.workspaceBar.reserveLayoutSpace,
                onChange: { newValue in updateSetting { $0.reserveLayoutSpace = newValue } },
                onReset: { updateSetting { $0.reserveLayoutSpace = nil } }
            )
            .help(
                "Reserve tiled layout space at the selected edge using the configured bar thickness."
            )

            OverridablePicker(
                label: String(localized: "Notch Mode"),
                value: ms.notchMode,
                globalValue: settings.workspaceBar.notchMode,
                options: WorkspaceBarNotchMode.allCases,
                displayName: { $0.displayName },
                onChange: { newValue in updateSetting { $0.notchMode = newValue } },
                onReset: { updateSetting { $0.notchMode = nil } }
            )
            .help(
                "Move below the notch, split around it, or fill the area to its left, covering application menus. Without a notch, Fill Left covers the left half of the menu bar. Notch modes are ignored at Bottom, Left, and Right."
            )

            OverridableSlider(
                label: String(localized: "Active Zone Width"),
                value: ms.notchActiveZoneWidth,
                globalValue: settings.workspaceBar.notchActiveZoneWidth,
                range: 100 ... 400,
                step: 10,
                formatter: { String(localized: "\(Int($0)) px") },
                onChange: { newValue in updateSetting { $0.notchActiveZoneWidth = newValue } },
                onReset: { updateSetting { $0.notchActiveZoneWidth = nil } }
            )
            .help("Width of the zone next to the notch that the focused workspace stays centered in")
        }

        Section("Position & Level") {
            OverridablePicker(
                label: String(localized: "Position"),
                value: ms.position,
                globalValue: settings.workspaceBar.position,
                options: WorkspaceBarPosition.allCases,
                displayName: { $0.displayName },
                onChange: { newValue in updateSetting { $0.position = newValue } },
                onReset: { updateSetting { $0.position = nil } }
            )

            OverridablePicker(
                label: String(localized: "Window Level"),
                value: ms.windowLevel,
                globalValue: settings.workspaceBar.windowLevel,
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
                globalValue: settings.workspaceBar.xOffset,
                step: 10,
                formatter: { String(localized: "\(Int($0)) px") },
                onChange: { newValue in updateSetting { $0.xOffset = newValue } },
                onReset: { updateSetting { $0.xOffset = nil } }
            )
            .help("Horizontal offset (negative = left, positive = right)")

            OverridableStepper(
                label: String(localized: "Y Offset"),
                value: ms.yOffset,
                globalValue: settings.workspaceBar.yOffset,
                step: 10,
                formatter: { String(localized: "\(Int($0)) px") },
                onChange: { newValue in updateSetting { $0.yOffset = newValue } },
                onReset: { updateSetting { $0.yOffset = nil } }
            )
            .help("Vertical offset (negative = down, positive = up)")
        }

        Section("Appearance") {
            OverridableSlider(
                label: String(localized: "Bar Thickness"),
                value: ms.height,
                globalValue: settings.workspaceBar.height,
                range: 20 ... 40,
                step: 2,
                formatter: { String(localized: "\(Int($0)) px") },
                onChange: { newValue in updateSetting { $0.height = newValue } },
                onReset: { updateSetting { $0.height = nil } }
            )

            OverridableSlider(
                label: String(localized: "Background Opacity"),
                value: ms.backgroundOpacity,
                globalValue: settings.workspaceBar.backgroundOpacity,
                range: 0 ... 0.5,
                step: 0.05,
                formatter: { "\(Int($0 * 100))%" },
                onChange: { newValue in updateSetting { $0.backgroundOpacity = newValue } },
                onReset: { updateSetting { $0.backgroundOpacity = nil } }
            )

            OverridableSlider(
                label: String(localized: "Inactive Icon Opacity"),
                value: ms.inactiveIconOpacity,
                globalValue: settings.workspaceBar.inactiveIconOpacity ?? 0.5,
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
                globalValue: settings.workspaceBar.transparentBackground,
                onChange: { newValue in updateSetting { $0.transparentBackground = newValue } },
                onReset: { updateSetting { $0.transparentBackground = nil } }
            )
            .help("Hide the workspace bar material, tint, and border while keeping its contents interactive.")

            OverridableToggle(
                label: String(localized: "Solid Black Background"),
                value: ms.solidBlackBackground,
                globalValue: settings.workspaceBar.solidBlackBackground,
                onChange: { newValue in updateSetting { $0.solidBlackBackground = newValue } },
                onReset: { updateSetting { $0.solidBlackBackground = nil } }
            )
            .help("Fill the workspace bar with fully opaque black, overriding the tint, material, and border.")

            OverridableToggle(
                label: String(localized: "Show Item Backgrounds"),
                value: ms.showItemBackgrounds,
                globalValue: settings.workspaceBar.showItemBackgrounds,
                onChange: { newValue in updateSetting { $0.showItemBackgrounds = newValue } },
                onReset: { updateSetting { $0.showItemBackgrounds = nil } }
            )
            .help("Show material backgrounds behind workspace groups, floating windows, scratchpad, and stats.")

            OverridableToggle(
                label: String(localized: "Show Accent Highlights"),
                value: ms.showAccentHighlights,
                globalValue: settings.workspaceBar.showAccentHighlights,
                onChange: { newValue in updateSetting { $0.showAccentHighlights = newValue } },
                onReset: { updateSetting { $0.showAccentHighlights = nil } }
            )
            .help("Show the focused-workspace outline and focused-icon accent glow.")
        }
    }
}
