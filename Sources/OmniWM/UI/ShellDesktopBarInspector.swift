// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct ShellDesktopBarInspector: View {
    let editor: ShellDesktopEditor
    @State private var confirmingReset = false

    var bar: WorkspaceBarSettings {
        editor.barSettings
    }

    var style: WorkspaceBarProfileOverride? {
        editor.barOverride
    }

    var body: some View {
        Group {
            if let monitor = editor.monitor {
                ShellDesktopBarDisplayInspector(editor: editor, monitor: monitor)
            } else {
                positionSection
                placementSection
                appearanceSection
                behaviorSection
            }
            effectsSection
            Section {
                Button("Reset Bar Settings to Style Defaults…") { confirmingReset = true }
            }
        }
        .confirmationDialog("Reset this style’s bar settings?", isPresented: $confirmingReset) {
            Button("Reset Bar Settings", role: .destructive) { editor.reset() }
        } message: {
            Text("Widget layout, display overrides, effects and All styles settings are kept.")
        }
    }

    func binding<Value: Encodable & Sendable>(
        _ key: String, value: Value, continuous: Bool = false, table: String = "workspaceBar"
    ) -> Binding<Value> {
        Binding(
            get: { editor.pending(editor.barTarget(key, table: table)) ?? value },
            set: { editor.set($0, key: key, table: table, continuous: continuous) }
        )
    }

    func slider(
        _ label: String, key: String, value: Double, range: ClosedRange<Double>, step: Double = 1,
        format: @escaping (Double) -> String
    ) -> some View {
        let current = editor.pending(editor.barTarget(key), as: Double.self) ?? value
        return SettingsSliderRow(
            label: label, value: binding(key, value: value, continuous: true), range: range, step: step,
            valueText: format(current)
        )
    }

    private var positionSection: some View {
        Section("Position & Level") {
            Picker("Position", selection: binding("position", value: style?.settings.position ?? bar.position)) {
                ForEach(WorkspaceBarPosition.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Full Width", isOn: binding("fullWidth", value: style?.settings.fullWidth ?? bar.fullWidth))
                .help("Span the whole edge of the screen, with each widget group pinned to its start, center, or end")
            Picker(
                "Window Level",
                selection: binding("windowLevel", value: style?.settings.windowLevel ?? bar.windowLevel)
            ) {
                ForEach(WorkspaceBarWindowLevel.allCases) { Text($0.displayName).tag($0) }
            }
            DisclosureGroup("Advanced Positioning") {
                offset(String(localized: "X Offset"), key: "xOffset", value: style?.settings.xOffset ?? bar.xOffset)
                    .help("Horizontal offset (negative = left, positive = right)")
                offset(String(localized: "Y Offset"), key: "yOffset", value: style?.settings.yOffset ?? bar.yOffset)
                    .help("Vertical offset (negative = down, positive = up)")
            }
        }
    }

    private var placementSection: some View {
        Section("Screen Placement") {
            Toggle("Reserve Space for Workspace Bar", isOn: binding(
                "reserveLayoutSpace", value: style?.settings.reserveLayoutSpace ?? bar.reserveLayoutSpace
            ))
            .help(
                "Reserve tiled layout space at the selected edge. Overlapping bars reserve only the portion below the menu bar."
            )
            if style?.settings.fullWidth ?? bar.fullWidth {
                Picker("Notch Mode", selection: binding(
                    "fullWidthNotchMode", value: style?.settings.fullWidthNotchMode ?? bar.fullWidthNotchMode
                )) {
                    ForEach(WorkspaceBarFullWidthNotchMode.allCases) { Text($0.displayName).tag($0) }
                }
            } else {
                Picker(
                    "Notch Mode",
                    selection: binding("notchMode", value: style?.settings.notchMode ?? bar.notchMode)
                ) {
                    ForEach(WorkspaceBarNotchMode.allCases) { Text($0.displayName).tag($0) }
                }
                if (style?.settings.notchMode ?? bar.notchMode).isSplit {
                    slider(
                        String(localized: "Active Zone Width"),
                        key: "notchActiveZoneWidth",
                        value: style?.settings.notchActiveZoneWidth ?? bar.notchActiveZoneWidth,
                        range: 100 ... 400,
                        step: 10,
                        format: { String(localized: "\(Int($0)) px") }
                    )
                    .help("Width of the zone next to the notch that the focused workspace stays centered in")
                }
            }
            SettingsCaption(localized: "Notch modes apply to the top edge only.")
        }
    }

    private func offset(_ label: String, key: String, value: Double) -> some View {
        SettingsNumberStepperRow(
            label: label, value: binding(key, value: value), step: 10,
            valueText: String(localized: "\(Int(value)) px")
        )
    }

    private var behaviorSection: some View {
        Section("Workspace Bar Behavior") {
            Toggle("Window Hover Previews", isOn: binding(
                "hoverPreviewsEnabled", value: style?.hoverPreviewsEnabled ?? bar.hoverPreviewsEnabled
            ))
            Picker("Notification Badges", selection: binding(
                "notificationBadges", value: style?.notificationBadges ?? bar.notificationBadges
            )) {
                Text("Off").tag(WorkspaceBarNotificationBadgeMode.off)
                Text("Dot").tag(WorkspaceBarNotificationBadgeMode.dot)
                Text("Text").tag(WorkspaceBarNotificationBadgeMode.text)
            }
            slider(
                String(localized: "Refresh Interval"),
                key: "notificationBadgeRefreshIntervalSeconds",
                value: style?.notificationBadgeRefreshIntervalSeconds ?? bar.notificationBadgeRefreshIntervalSeconds,
                range: 1 ... 60,
                step: 1,
                format: { String(localized: "\(Int($0)) s") }
            )
            .disabled(bar.resolvedNotificationBadges == .off)
            Toggle(
                "Show Workspace Labels",
                isOn: binding("showLabels", value: style?.settings.showLabels ?? bar.showLabels)
            )
            Toggle("Show Floating Windows", isOn: binding(
                "showFloatingWindows", value: style?.settings.showFloatingWindows ?? bar.showFloatingWindows
            ))
            Toggle("Deduplicate App Icons", isOn: binding(
                "deduplicateAppIcons", value: style?.settings.deduplicateAppIcons ?? bar.deduplicateAppIcons
            ))
            .help("Group workspace windows by app with badge counts; scratchpad pills always group by app")
            Toggle("Hide Empty Workspaces", isOn: binding(
                "hideEmptyWorkspaces", value: style?.settings.hideEmptyWorkspaces ?? bar.hideEmptyWorkspaces
            ))
            Toggle("Automatically hide and show the workspace bar", isOn: binding(
                "autoHide", value: style?.settings.autoHide ?? bar.autoHide
            ))
            .help(
                "Show at the bar edge; hide when the pointer moves inward past the bar and interactions end. Never reserves layout space."
            )
            if (style?.settings.autoHide ?? bar.autoHide)
                || style?.monitorOverrides.contains(where: { $0.autoHide == true }) == true
                || bar.monitorOverrides.contains(where: { $0.autoHide == true })
            {
                slider(
                    String(localized: "Auto-Hide Reveal Delay"),
                    key: "autoHideRevealDelayMilliseconds",
                    value: style?.autoHideRevealDelayMilliseconds ?? bar.autoHideRevealDelayMilliseconds,
                    range: 0 ... 1000,
                    step: 50,
                    format: { String(localized: "\(Int($0)) ms") }
                )
                slider(
                    String(localized: "Auto-Hide Hide Delay"),
                    key: "autoHideHideDelayMilliseconds",
                    value: style?.autoHideHideDelayMilliseconds ?? bar.autoHideHideDelayMilliseconds,
                    range: 0 ... 1000,
                    step: 50,
                    format: { String(localized: "\(Int($0)) ms") }
                )
            }
            Picker("Reveal on Modifier Hold", selection: binding(
                "revealModifier", value: style?.revealModifier ?? bar.revealModifier
            )) {
                ForEach(WorkspaceBarRevealModifier.allCases, id: \.self) { Text($0.localizedDisplayName).tag($0) }
            }
            .help("Reveal the workspace bar while holding these modifiers. Can be combined with automatic hiding.")
            if bar.resolvedRevealModifier != .off {
                slider(
                    String(localized: "Reveal Hold Delay"),
                    key: "revealHoldMilliseconds",
                    value: style?.revealHoldMilliseconds ?? bar.revealHoldMilliseconds,
                    range: 0 ... 1000,
                    step: 50,
                    format: { String(localized: "\(Int($0)) ms") }
                )
            }
            Toggle("Hide in Native Fullscreen", isOn: binding(
                "hideInNativeFullscreen", value: style?.hideInNativeFullscreen ?? bar.hideInNativeFullscreen
            ))
            .help("Hide the bar on a monitor while it shows a native fullscreen window")
            Toggle("System Stats Button", isOn: Binding(
                get: {
                    guard let config = editor.snapshot?.config else { return false }
                    return (style?.systemStatsButton ?? bar.systemStatsButton) && config.hasSystemStatsButtonPlace
                },
                set: editor.setSystemStats
            ))
            .help("Show a small workspace bar button that opens a system stats popup")
        }
    }
}
