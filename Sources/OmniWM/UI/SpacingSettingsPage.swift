// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct SpacingSettingsPage: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var selectedGapMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    var body: some View {
        Form {
            MonitorScopeSection(
                selectedMonitor: $selectedGapMonitor,
                monitors: connectedMonitors,
                field: .monitorGapOverrides,
                overrideID: { settings.gaps.settings(for: $0)?.id.uuidString },
                reset: { monitor in
                    settings.gaps.remove(for: monitor)
                    controller.updateMonitorGapSettings()
                }
            )

            Section("Layout") {
                if let monitorId = selectedGapMonitor,
                   let monitor = connectedMonitors.first(where: { $0.id == monitorId })
                {
                    let overrides = settings.gaps.settings(for: monitor)
                    OverridableSlider(
                        field: .init(.monitorGapOverrides, row: overrides?.id.uuidString, leaf: "innerGap"),
                        label: String(localized: "Inner Gaps"),
                        value: overrides?.innerGap,
                        globalValue: settings.gaps.size,
                        range: 0 ... 32,
                        step: 1,
                        formatter: { String(localized: "\(Int($0)) px") },
                        onChange: { value in updateGapSetting(for: monitor) { $0.innerGap = value } },
                        onReset: { updateGapSetting(for: monitor) { $0.innerGap = nil } }
                    )
                    SettingsCaption(localized: "Overrides the global inner gap for \(monitor.name).")
                } else {
                    SettingsSliderRow(
                        field: .init(.gapsSize),
                        label: String(localized: "Inner Gaps"),
                        value: Bindable(settings.gaps).size,
                        range: 0 ... 32,
                        step: 1,
                        valueText: String(localized: "\(Int(settings.gaps.size)) px"),
                        valueWidth: 64
                    )
                    .id("Inner Gaps")
                    .onChange(of: settings.gaps.size) { _, newValue in
                        controller.setGapSize(newValue)
                    }
                }
            }
            .id("Layout")

            Section("Outer Margins") {
                if let monitorId = selectedGapMonitor,
                   let monitor = connectedMonitors.first(where: { $0.id == monitorId })
                {
                    let overrides = settings.gaps.settings(for: monitor)
                    let row = overrides?.id.uuidString
                    OverridableSlider(
                        field: .init(.monitorGapOverrides, row: row, leaf: "outerGapLeft"),
                        label: String(localized: "Left"),
                        value: overrides?.outerGapLeft,
                        globalValue: settings.gaps.outerGapLeft,
                        range: 0 ... 64,
                        step: 1,
                        formatter: { String(localized: "\(Int($0)) px") },
                        onChange: { value in updateGapSetting(for: monitor) { $0.outerGapLeft = value } },
                        onReset: { updateGapSetting(for: monitor) { $0.outerGapLeft = nil } }
                    )
                    OverridableSlider(
                        field: .init(.monitorGapOverrides, row: row, leaf: "outerGapRight"),
                        label: String(localized: "Right"),
                        value: overrides?.outerGapRight,
                        globalValue: settings.gaps.outerGapRight,
                        range: 0 ... 64,
                        step: 1,
                        formatter: { String(localized: "\(Int($0)) px") },
                        onChange: { value in updateGapSetting(for: monitor) { $0.outerGapRight = value } },
                        onReset: { updateGapSetting(for: monitor) { $0.outerGapRight = nil } }
                    )
                    OverridableSlider(
                        field: .init(.monitorGapOverrides, row: row, leaf: "outerGapTop"),
                        label: String(localized: "Top"),
                        value: overrides?.outerGapTop,
                        globalValue: settings.gaps.outerGapTop,
                        range: 0 ... 64,
                        step: 1,
                        formatter: { String(localized: "\(Int($0)) px") },
                        onChange: { value in updateGapSetting(for: monitor) { $0.outerGapTop = value } },
                        onReset: { updateGapSetting(for: monitor) { $0.outerGapTop = nil } }
                    )
                    OverridableSlider(
                        field: .init(.monitorGapOverrides, row: row, leaf: "outerGapBottom"),
                        label: String(localized: "Bottom"),
                        value: overrides?.outerGapBottom,
                        globalValue: settings.gaps.outerGapBottom,
                        range: 0 ... 64,
                        step: 1,
                        formatter: { String(localized: "\(Int($0)) px") },
                        onChange: { value in updateGapSetting(for: monitor) { $0.outerGapBottom = value } },
                        onReset: { updateGapSetting(for: monitor) { $0.outerGapBottom = nil } }
                    )
                    OverridableToggle(
                        field: .init(.monitorGapOverrides, row: row, leaf: "fullscreenUsesOuterGaps"),
                        label: String(localized: "Keep Outer Margins in Full Screen"),
                        value: overrides?.fullscreenUsesOuterGaps,
                        globalValue: settings.gaps.fullscreenUsesOuterGaps,
                        onChange: { value in
                            updateGapSetting(for: monitor) { $0.fullscreenUsesOuterGaps = value }
                        },
                        onReset: { updateGapSetting(for: monitor) { $0.fullscreenUsesOuterGaps = nil } }
                    )
                    SettingsCaption(String(
                        localized: "Overrides selected global outer-margin values for \(monitor.name). \(topGapCaption(overrides?.outerGapTop ?? settings.gaps.outerGapTop, on: monitor))"
                    ))
                    SettingsCaption(
                        localized: "Keeps these margins for OmniWM Full Screen and the Single Window ‘Full Screen’ fit. Any active Workspace Bar reservation is also kept; native macOS Full Screen is unchanged."
                    )
                } else {
                    SettingsSliderRow(
                        field: .init(.gapsOuterLeft),
                        label: String(localized: "Left"),
                        value: Bindable(settings.gaps).outerGapLeft,
                        range: 0 ... 64,
                        step: 1,
                        valueText: String(localized: "\(Int(settings.gaps.outerGapLeft)) px"),
                        valueWidth: 64
                    )
                    .id("Left")
                    .onChange(of: settings.gaps.outerGapLeft) { _, _ in syncOuterGaps() }

                    SettingsSliderRow(
                        field: .init(.gapsOuterRight),
                        label: String(localized: "Right"),
                        value: Bindable(settings.gaps).outerGapRight,
                        range: 0 ... 64,
                        step: 1,
                        valueText: String(localized: "\(Int(settings.gaps.outerGapRight)) px"),
                        valueWidth: 64
                    )
                    .id("Right")
                    .onChange(of: settings.gaps.outerGapRight) { _, _ in syncOuterGaps() }

                    SettingsSliderRow(
                        field: .init(.gapsOuterTop),
                        label: String(localized: "Top"),
                        value: Bindable(settings.gaps).outerGapTop,
                        range: 0 ... 64,
                        step: 1,
                        valueText: String(localized: "\(Int(settings.gaps.outerGapTop)) px"),
                        valueWidth: 64
                    )
                    .id("Top")
                    .onChange(of: settings.gaps.outerGapTop) { _, _ in syncOuterGaps() }
                    if let mainMonitor = connectedMonitors.first(where: \.isMain) {
                        SettingsCaption(topGapCaption(settings.gaps.outerGapTop, on: mainMonitor))
                    }

                    SettingsSliderRow(
                        field: .init(.gapsOuterBottom),
                        label: String(localized: "Bottom"),
                        value: Bindable(settings.gaps).outerGapBottom,
                        range: 0 ... 64,
                        step: 1,
                        valueText: String(localized: "\(Int(settings.gaps.outerGapBottom)) px"),
                        valueWidth: 64
                    )
                    .id("Bottom")
                    .onChange(of: settings.gaps.outerGapBottom) { _, _ in syncOuterGaps() }

                    Toggle(
                        "Keep Outer Margins in Full Screen",
                        isOn: Bindable(settings.gaps).fullscreenUsesOuterGaps
                    )
                    .settingsField(.gapsFullscreenUsesOuterGaps)
                    .onChange(of: settings.gaps.fullscreenUsesOuterGaps) { _, _ in
                        controller.updateMonitorGapSettings()
                    }

                    SettingsCaption(
                        localized: "Keeps these margins for OmniWM Full Screen and the Single Window ‘Full Screen’ fit. Any active Workspace Bar reservation is also kept; native macOS Full Screen is unchanged."
                    )
                }
            }
            .id("Outer Margins")
        }
        .formStyle(.grouped)
        .onAppear { connectedMonitors = Monitor.current() }
    }

    private func topGapCaption(_ top: Double, on monitor: Monitor) -> String {
        let menuBarInset = Int(max(0, monitor.frame.maxY - monitor.visibleFrame.maxY))
        let belowMenuBar = max(0, Int(top) - menuBarInset)
        return String(
            localized: "Top is measured from the screen's physical top edge: \(Int(top)) px → \(belowMenuBar) px below the menu bar on \(monitor.name)."
        )
    }

    private func syncOuterGaps() {
        controller.updateMonitorGapSettings()
    }

    private func updateGapSetting(for monitor: Monitor, _ update: (inout MonitorGapSettings) -> Void) {
        var ms = settings.gaps.settings(for: monitor) ?? MonitorGapSettings(
            monitorName: monitor.name
        )
        update(&ms)
        settings.gaps.update(ms, for: monitor)
        controller.updateMonitorGapSettings()
    }
}
