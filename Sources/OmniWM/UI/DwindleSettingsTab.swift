// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct DwindleSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    var body: some View {
        Form {
            MonitorScopeSection(
                selectedMonitor: $selectedMonitor,
                monitors: connectedMonitors,
                hasOverrides: { settings.dwindle.settings(for: $0) != nil },
                reset: { monitor in
                    settings.dwindle.remove(for: monitor)
                    controller.updateMonitorDwindleSettings()
                }
            )

            if let monitorId = selectedMonitor,
               let monitor = connectedMonitors.first(where: { $0.id == monitorId })
            {
                MonitorDwindleSettingsSection(
                    settings: settings,
                    controller: controller,
                    monitor: monitor
                )
            } else {
                GlobalDwindleSettingsSection(
                    settings: settings,
                    controller: controller
                )
            }
        }
        .formStyle(.grouped)
        .onAppear {
            connectedMonitors = Monitor.current()
        }
    }
}

private struct GlobalDwindleSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        Section("Dwindle Layout") {
            Toggle("Smart Split", isOn: Bindable(settings.dwindle).smartSplit)
                .onChange(of: settings.dwindle.smartSplit) { _, newValue in
                    controller.updateDwindleConfig(smartSplit: newValue)
                }
            SettingsCaption(localized: "Automatically choose split direction based on cursor position")

            Toggle("Move to Root: Stable", isOn: Bindable(settings.dwindle).moveToRootStable)
            SettingsCaption(localized: "Keep window on same screen side when moving to root")

            Toggle("Stack Incoming Windows", isOn: Bindable(settings.dwindle).stackIncomingWindows)
                .onChange(of: settings.dwindle.stackIncomingWindows) { _, newValue in
                    controller.updateDwindleConfig(stackIncomingWindows: newValue)
                }
            SettingsCaption(
                localized: "Newly opened and moved windows join the focused tile's stack instead of splitting it"
            )

            SettingsSliderRow(
                label: String(localized: "Default Split Ratio"),
                value: Bindable(settings.dwindle).defaultSplitRatio,
                range: 0.1 ... 1.9,
                step: 0.1,
                valueText: settings.dwindle.defaultSplitRatio.formatted(.number.precision(.fractionLength(1))),
                valueWidth: 40
            )
            .onChange(of: settings.dwindle.defaultSplitRatio) { _, newValue in
                controller.updateDwindleConfig(defaultSplitRatio: CGFloat(newValue))
            }
            SettingsCaption(localized: "1.0 = equal split, <1.0 = first smaller, >1.0 = first larger")

            SettingsSliderRow(
                label: String(localized: "Split Width Multiplier"),
                value: Bindable(settings.dwindle).splitWidthMultiplier,
                range: 0.5 ... 2.0,
                step: 0.1,
                valueText: settings.dwindle.splitWidthMultiplier.formatted(.number.precision(.fractionLength(1))),
                valueWidth: 40
            )
            .onChange(of: settings.dwindle.splitWidthMultiplier) { _, newValue in
                controller.updateDwindleConfig(splitWidthMultiplier: CGFloat(newValue))
            }
            SettingsCaption(localized: "Affects when to prefer vertical vs horizontal splits")

            SingleWindowFitControls(
                label: String(localized: "Single Window"),
                fit: settings.dwindle.singleWindowFit,
                modes: SingleWindowFit.dwindleModes,
                onChange: { newValue in
                    settings.dwindle.singleWindowFit = newValue
                    controller.updateDwindleConfig(singleWindowFit: newValue)
                }
            )
            SettingsCaption(
                localized: "How a lone window is sized: Full Screen fills the work area; Custom uses a fixed width × height"
            )

            Toggle("Use Global Gap Settings", isOn: Bindable(settings.dwindle).useGlobalGaps)
                .onChange(of: settings.dwindle.useGlobalGaps) { _, _ in
                    controller.updateDwindleConfig()
                }
            SettingsCaption(localized: "When enabled, uses the gap values from General settings")
        }
    }
}

private struct MonitorDwindleSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor

    private var monitorSettings: MonitorDwindleSettings {
        settings.dwindle.settings(for: monitor) ?? MonitorDwindleSettings(
            monitorName: monitor.name
        )
    }

    private func updateSetting(_ update: (inout MonitorDwindleSettings) -> Void) {
        var ms = monitorSettings
        update(&ms)
        settings.dwindle.update(ms, for: monitor)
        controller.updateMonitorDwindleSettings()
    }

    var body: some View {
        let ms = monitorSettings
        let usesGlobalGaps = ms.useGlobalGaps ?? settings.dwindle.useGlobalGaps

        Section("Dwindle Layout") {
            OverridableToggle(
                label: String(localized: "Smart Split"),
                value: ms.smartSplit,
                globalValue: settings.dwindle.smartSplit,
                onChange: { newValue in updateSetting { $0.smartSplit = newValue } },
                onReset: { updateSetting { $0.smartSplit = nil } }
            )
            SettingsCaption(localized: "Automatically choose split direction based on cursor position")

            OverridableToggle(
                label: String(localized: "Stack Incoming Windows"),
                value: ms.stackIncomingWindows,
                globalValue: settings.dwindle.stackIncomingWindows,
                onChange: { newValue in updateSetting { $0.stackIncomingWindows = newValue } },
                onReset: { updateSetting { $0.stackIncomingWindows = nil } }
            )

            OverridableSlider(
                label: String(localized: "Default Split Ratio"),
                value: ms.defaultSplitRatio,
                globalValue: settings.dwindle.defaultSplitRatio,
                range: 0.1 ... 1.9,
                step: 0.1,
                formatter: { $0.formatted(.number.precision(.fractionLength(1))) },
                onChange: { newValue in updateSetting { $0.defaultSplitRatio = newValue } },
                onReset: { updateSetting { $0.defaultSplitRatio = nil } }
            )
            SettingsCaption(localized: "1.0 = equal split, <1.0 = first smaller, >1.0 = first larger")

            OverridableSlider(
                label: String(localized: "Split Width Multiplier"),
                value: ms.splitWidthMultiplier,
                globalValue: settings.dwindle.splitWidthMultiplier,
                range: 0.5 ... 2.0,
                step: 0.1,
                formatter: { $0.formatted(.number.precision(.fractionLength(1))) },
                onChange: { newValue in updateSetting { $0.splitWidthMultiplier = newValue } },
                onReset: { updateSetting { $0.splitWidthMultiplier = nil } }
            )
            SettingsCaption(localized: "Affects when to prefer vertical vs horizontal splits")

            SingleWindowFitControls(
                label: String(localized: "Single Window"),
                fit: ms.singleWindowFit ?? settings.dwindle.singleWindowFit,
                modes: SingleWindowFit.dwindleModes,
                isOverridden: ms.singleWindowFit != nil,
                onChange: { newValue in updateSetting { $0.singleWindowFit = newValue } },
                onReset: { updateSetting { $0.singleWindowFit = nil } }
            )

            OverridableToggle(
                label: String(localized: "Use Global Gap Settings"),
                value: ms.useGlobalGaps,
                globalValue: settings.dwindle.useGlobalGaps,
                onChange: { newValue in updateSetting { $0.useGlobalGaps = newValue } },
                onReset: { updateSetting { $0.useGlobalGaps = nil } }
            )
            SettingsCaption(localized: "When enabled, uses the gap values from General settings")
        }

        if !usesGlobalGaps {
            Section("Dwindle Gaps") {
                OverridableSlider(
                    label: String(localized: "Inner Gap"),
                    value: ms.innerGap,
                    globalValue: settings.gaps.size,
                    range: 0 ... 32,
                    step: 1,
                    formatter: { String(localized: "\(Int($0)) px") },
                    onChange: { newValue in updateSetting { $0.innerGap = newValue } },
                    onReset: { updateSetting { $0.innerGap = nil } }
                )
            }
        }
    }
}
