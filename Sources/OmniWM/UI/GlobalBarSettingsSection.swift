// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct GlobalBarSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var editError: String?
    var pane: WorkspaceBarSettingsPane = .behavior

    var style: WorkspaceBarProfileOverride? {
        settings.workspaceBar.profileOverride
    }

    var body: some View {
        Group {
            switch pane {
            case .layout:
                positionSections
                layoutBehaviorSection
            case .appearance:
                appearanceSection
            case .behavior:
                behaviorSection
            case .apps:
                EmptyView()
            }
        }
        .shellSettingsError($editError)
    }

    func profileBinding<Value: Encodable>(_ key: String, value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { next in
            edit { try await ShellSettingsEdits.set(next, key: key, settings: settings, controller: controller) }
        })
    }

    func edit(_ change: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await change() } catch { editError = error.localizedDescription }
        }
    }

    private var systemStatsBinding: Binding<Bool> {
        Binding(
            get: {
                let config = controller.workspaceBarManager.shellConfiguration.config
                guard let widget = config.systemStatsWidget else { return false }
                return (style?.systemStatsButton ?? settings.workspaceBar.systemStatsButton)
                    && config.barLane(of: widget) != nil
            },
            set: { enabled in
                edit {
                    try await ShellSettingsEdits.setSystemStatsEnabled(
                        enabled,
                        settings: settings,
                        controller: controller
                    )
                }
            }
        )
    }
}

extension GlobalBarSettingsSection {
    private var behaviorSection: some View {
        Section("Workspace Bar") {
            Toggle(
                "Window Hover Previews",
                isOn: profileBinding(
                    "hoverPreviewsEnabled",
                    value: style?.hoverPreviewsEnabled ?? settings.workspaceBar.hoverPreviewsEnabled
                )
            )

            Picker(
                "Notification Badges",
                selection: profileBinding(
                    "notificationBadges",
                    value: style?.notificationBadges ?? settings.workspaceBar.notificationBadges
                )
            ) {
                Text("Off").tag(WorkspaceBarNotificationBadgeMode.off)
                Text("Dot").tag(WorkspaceBarNotificationBadgeMode.dot)
                Text("Text").tag(WorkspaceBarNotificationBadgeMode.text)
            }

            SettingsSliderRow(
                label: String(localized: "Refresh Interval"),
                value: profileBinding(
                    "notificationBadgeRefreshIntervalSeconds",
                    value: style?.notificationBadgeRefreshIntervalSeconds ?? settings.workspaceBar
                        .notificationBadgeRefreshIntervalSeconds
                ),
                range: 1 ... 60,
                step: 1,
                valueText: String(
                    localized: "\(Int(style?.notificationBadgeRefreshIntervalSeconds ?? settings.workspaceBar.notificationBadgeRefreshIntervalSeconds)) s"
                )
            )
            .disabled(settings.workspaceBar.resolvedNotificationBadges == .off)

            Toggle(
                "Show Workspace Labels",
                isOn: profileBinding(
                    "showLabels",
                    value: style?.settings.showLabels ?? settings.workspaceBar.showLabels
                )
            )

            Toggle(
                "Show Floating Windows",
                isOn: profileBinding(
                    "showFloatingWindows",
                    value: style?.settings.showFloatingWindows ?? settings.workspaceBar.showFloatingWindows
                )
            )

            Toggle(
                "Deduplicate App Icons",
                isOn: profileBinding(
                    "deduplicateAppIcons",
                    value: style?.settings.deduplicateAppIcons ?? settings.workspaceBar.deduplicateAppIcons
                )
            )
            .help("Group workspace windows by app with badge counts; scratchpad pills always group by app")

            Toggle(
                "Hide Empty Workspaces",
                isOn: profileBinding(
                    "hideEmptyWorkspaces",
                    value: style?.settings.hideEmptyWorkspaces ?? settings.workspaceBar.hideEmptyWorkspaces
                )
            )

            Toggle(
                "Automatically hide and show the workspace bar",
                isOn: profileBinding("autoHide", value: style?.settings.autoHide ?? settings.workspaceBar.autoHide)
            )
            .help(
                "Show at the bar edge; hide when the pointer moves inward past the bar and interactions end. Never reserves layout space."
            )

            if (style?.settings.autoHide ?? settings.workspaceBar.autoHide)
                || style?.monitorOverrides.contains(where: { $0.autoHide == true }) == true
                || settings.workspaceBar.monitorOverrides.contains(where: { $0.autoHide == true })
            {
                SettingsSliderRow(
                    label: String(localized: "Auto-Hide Reveal Delay"),
                    value: profileBinding(
                        "autoHideRevealDelayMilliseconds",
                        value: style?.autoHideRevealDelayMilliseconds ?? settings.workspaceBar
                            .autoHideRevealDelayMilliseconds
                    ),
                    range: 0 ... 1000,
                    step: 50,
                    valueText: String(
                        localized: "\(Int(style?.autoHideRevealDelayMilliseconds ?? settings.workspaceBar.autoHideRevealDelayMilliseconds)) ms"
                    )
                )

                SettingsSliderRow(
                    label: String(localized: "Auto-Hide Hide Delay"),
                    value: profileBinding(
                        "autoHideHideDelayMilliseconds",
                        value: style?.autoHideHideDelayMilliseconds ?? settings.workspaceBar
                            .autoHideHideDelayMilliseconds
                    ),
                    range: 0 ... 1000,
                    step: 50,
                    valueText: String(
                        localized: "\(Int(style?.autoHideHideDelayMilliseconds ?? settings.workspaceBar.autoHideHideDelayMilliseconds)) ms"
                    )
                )
            }

            Picker(
                "Reveal on Modifier Hold",
                selection: profileBinding(
                    "revealModifier",
                    value: style?.revealModifier ?? settings.workspaceBar.revealModifier
                )
            ) {
                ForEach(WorkspaceBarRevealModifier.allCases, id: \.self) { modifier in
                    Text(modifier.localizedDisplayName).tag(modifier)
                }
            }
            .help("Reveal the workspace bar while holding these modifiers. Can be combined with automatic hiding.")

            if settings.workspaceBar.resolvedRevealModifier != .off {
                SettingsSliderRow(
                    label: String(localized: "Reveal Hold Delay"),
                    value: profileBinding(
                        "revealHoldMilliseconds",
                        value: style?.revealHoldMilliseconds ?? settings.workspaceBar.revealHoldMilliseconds
                    ),
                    range: 0 ... 1000,
                    step: 50,
                    valueText: String(
                        localized: "\(Int(style?.revealHoldMilliseconds ?? settings.workspaceBar.revealHoldMilliseconds)) ms"
                    )
                )
            }

            Toggle(
                "Hide in Native Fullscreen",
                isOn: profileBinding(
                    "hideInNativeFullscreen",
                    value: style?.hideInNativeFullscreen ?? settings.workspaceBar.hideInNativeFullscreen
                )
            )
            .help(
                "Hide the bar on a monitor while it shows a native fullscreen window"
            )

            Toggle(
                "System Stats Button",
                isOn: systemStatsBinding
            )
            .help("Show a small workspace bar button that opens a system stats popup")
        }
    }

    private var layoutBehaviorSection: some View {
        Section("Screen Placement") {
            Toggle(
                "Reserve Space for Workspace Bar",
                isOn: profileBinding(
                    "reserveLayoutSpace",
                    value: style?.settings.reserveLayoutSpace ?? settings.workspaceBar.reserveLayoutSpace
                )
            )
            .help(
                "Reserve tiled layout space at the selected edge. Overlapping bars reserve only the portion below the menu bar."
            )

            if style?.settings.fullWidth ?? settings.workspaceBar.fullWidth {
                Picker(
                    "Notch Mode",
                    selection: profileBinding(
                        "fullWidthNotchMode",
                        value: style?.settings.fullWidthNotchMode ?? settings.workspaceBar.fullWidthNotchMode
                    )
                ) {
                    ForEach(WorkspaceBarFullWidthNotchMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .help(
                    "Where the Center widgets go on a display with a notch: centered under it (Off), with the whole bar below the menu bar, beside the notch, or split around it, with the first half on its left. Notch modes are ignored at Bottom, Left, and Right."
                )
            } else {
                Picker(
                    "Notch Mode",
                    selection: profileBinding(
                        "notchMode",
                        value: style?.settings.notchMode ?? settings.workspaceBar.notchMode
                    )
                ) {
                    ForEach(WorkspaceBarNotchMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .help(
                    "Move below the menu bar, place it to the right of the notch (centered on displays without a notch), split around it, or fill the area to its left, covering application menus. Without a notch, Fill Left covers the left half of the menu bar. Notch modes are ignored at Bottom, Left, and Right."
                )
            }

            if !(style?.settings.fullWidth ?? settings.workspaceBar.fullWidth),
               (style?.settings.notchMode ?? settings.workspaceBar.notchMode).isSplit
            {
                SettingsSliderRow(
                    label: String(localized: "Active Zone Width"),
                    value: profileBinding(
                        "notchActiveZoneWidth",
                        value: style?.settings.notchActiveZoneWidth ?? settings.workspaceBar.notchActiveZoneWidth
                    ),
                    range: 100 ... 400,
                    step: 10,
                    valueText: String(
                        localized: "\(Int(style?.settings.notchActiveZoneWidth ?? settings.workspaceBar.notchActiveZoneWidth)) px"
                    )
                )
                .help("Width of the zone next to the notch that the focused workspace stays centered in")
            }
        }
    }

    @ViewBuilder
    private var positionSections: some View {
        Section("Position & Level") {
            Picker(
                "Position",
                selection: profileBinding("position", value: style?.settings.position ?? settings.workspaceBar.position)
            ) {
                ForEach(WorkspaceBarPosition.allCases) { position in
                    Text(position.displayName).tag(position)
                }
            }

            Toggle(
                "Full Width",
                isOn: profileBinding("fullWidth", value: style?.settings.fullWidth ?? settings.workspaceBar.fullWidth)
            )
            .help(
                "Span the whole edge of the screen, with each widget group pinned to its start, center, or end"
            )

            Picker(
                "Window Level",
                selection: profileBinding(
                    "windowLevel",
                    value: style?.settings.windowLevel ?? settings.workspaceBar.windowLevel
                )
            ) {
                ForEach(WorkspaceBarWindowLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
        }

        Section {
            DisclosureGroup("Advanced Positioning") {
                SettingsNumberStepperRow(
                    label: String(localized: "X Offset"),
                    value: profileBinding("xOffset", value: style?.settings.xOffset ?? settings.workspaceBar.xOffset),
                    step: 10,
                    valueText: String(localized: "\(Int(style?.settings.xOffset ?? settings.workspaceBar.xOffset)) px")
                )
                .help("Horizontal offset (negative = left, positive = right)")

                SettingsNumberStepperRow(
                    label: String(localized: "Y Offset"),
                    value: profileBinding("yOffset", value: style?.settings.yOffset ?? settings.workspaceBar.yOffset),
                    step: 10,
                    valueText: String(localized: "\(Int(style?.settings.yOffset ?? settings.workspaceBar.yOffset)) px")
                )
                .help("Vertical offset (negative = down, positive = up)")
            }
        }
    }
}
