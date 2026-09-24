// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct NiriSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    var body: some View {
        Form {
            MonitorScopeSection(
                selectedMonitor: $selectedMonitor,
                monitors: connectedMonitors,
                hasOverrides: { settings.niri.settings(for: $0) != nil },
                reset: { monitor in
                    settings.niri.remove(for: monitor)
                    controller.updateMonitorNiriSettings()
                }
            )

            if let monitorId = selectedMonitor,
               let monitor = connectedMonitors.first(where: { $0.id == monitorId })
            {
                MonitorNiriSettingsSection(
                    settings: settings,
                    controller: controller,
                    monitor: monitor
                )
            } else {
                GlobalNiriSettingsSection(
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

private struct GlobalNiriSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        let useAutoDefaultContainerPrimarySpan = Binding(
            get: { settings.niri.defaultContainerPrimarySpan == nil },
            set: { useAuto in
                settings
                    .niri
                    .defaultContainerPrimarySpan = useAuto ? nil :
                    (settings.niri.defaultContainerPrimarySpan ?? 0.5)
                controller.updateNiriConfig(defaultContainerPrimarySpan: settings.niri.defaultContainerPrimarySpan)
                controller.balanceNiriSizesAllWorkspaces()
            }
        )
        let defaultContainerPrimarySpanPercent = Binding(
            get: { Int((settings.niri.defaultContainerPrimarySpan ?? 0.5) * 100) },
            set: { newPercent in
                settings.niri.defaultContainerPrimarySpan = Double(min(100, max(5, newPercent))) / 100.0
                controller.updateNiriConfig(defaultContainerPrimarySpan: settings.niri.defaultContainerPrimarySpan)
                controller.balanceNiriSizesAllWorkspaces()
            }
        )
        let presets = settings.niri.containerPrimarySpanPresets

        Section("Niri Layout") {
            SettingsSliderRow(
                label: String(localized: "Visible Containers"),
                value: Binding(
                    get: { Double(settings.niri.visibleContainerCount) },
                    set: { settings.niri.visibleContainerCount = Int($0) }
                ),
                range: 1 ... 5,
                step: 1,
                valueText: "\(settings.niri.visibleContainerCount)",
                valueWidth: 32
            )
            .onChange(of: settings.niri.visibleContainerCount) { _, newValue in
                settings.niri.defaultContainerPrimarySpan = nil
                controller.updateNiriConfig(
                    visibleContainerCount: newValue,
                    defaultContainerPrimarySpan: settings.niri.defaultContainerPrimarySpan
                )
                controller.balanceNiriSizesAllWorkspaces()
            }

            Toggle("Infinite Loop Navigation", isOn: Bindable(settings.niri).infiniteLoop)
                .onChange(of: settings.niri.infiniteLoop) { _, newValue in
                    controller.updateNiriConfig(infiniteLoop: newValue)
                }

            Picker("Center Focused Column", selection: Bindable(settings.niri).centerFocusedColumn) {
                ForEach(CenterFocusedColumn.allCases, id: \.self) { mode in
                    Text(mode.localizedDisplayName).tag(mode)
                }
            }
            .onChange(of: settings.niri.centerFocusedColumn) { _, newValue in
                controller.updateNiriConfig(centerFocusedColumn: newValue)
            }

            Toggle("Always Center Single Column", isOn: Bindable(settings.niri).alwaysCenterSingleColumn)
                .onChange(of: settings.niri.alwaysCenterSingleColumn) { _, newValue in
                    controller.updateNiriConfig(alwaysCenterSingleColumn: newValue)
                }

            SingleWindowFitControls(
                label: String(localized: "Single Window"),
                fit: settings.niri.singleWindowFit,
                modes: SingleWindowFit.niriModes,
                onChange: { newValue in
                    settings.niri.singleWindowFit = newValue
                    controller.updateNiriConfig(singleWindowFit: newValue)
                }
            )
            SettingsCaption(
                localized: "How a lone window is sized: Full Screen fills the work area; Custom uses a fixed width × height; Container Primary Span keeps the configured primary span."
            )
        }

        Section("Default New Container Primary Span") {
            Picker("Span Mode", selection: useAutoDefaultContainerPrimarySpan) {
                Text("Auto").tag(true)
                Text("Custom").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)

            if settings.niri.defaultContainerPrimarySpan != nil {
                LabeledContent("Custom Span") {
                    HStack {
                        TextField("Custom Span", value: defaultContainerPrimarySpanPercent, format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                        Text("%")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCaption(
                settings.niri.defaultContainerPrimarySpan == nil
                    ? String(localized: "Auto divides the primary axis by the Visible Containers setting.")
                    : String(localized: "New or claimed containers start at this primary span until you resize them.")
            )
        }

        Section("Container Primary Span Presets") {
            ForEach(presets.indices, id: \.self) { index in
                LabeledContent("Preset \(index + 1)") {
                    HStack {
                        TextField("Preset \(index + 1)", value: Binding(
                            get: { Int(presets[index] * 100) },
                            set: { newPercent in
                                var current = settings.niri.containerPrimarySpanPresets
                                current[index] = Double(min(100, max(5, newPercent))) / 100.0
                                settings.niri.containerPrimarySpanPresets = current
                                controller
                                    .updateNiriConfig(containerPrimarySpanPresets: settings
                                        .niri.containerPrimarySpanPresets)
                            }
                        ), format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Preset \(index + 1) primary span")
                        Text("%")
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            var presets = settings.niri.containerPrimarySpanPresets
                            presets.remove(at: index)
                            settings.niri.containerPrimarySpanPresets = presets
                            controller
                                .updateNiriConfig(containerPrimarySpanPresets: settings.niri
                                    .containerPrimarySpanPresets)
                        } label: {
                            Label("Remove preset \(index + 1)", systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove preset \(index + 1)")
                        .disabled(settings.niri.containerPrimarySpanPresets.count <= 2)
                    }
                }
            }

            HStack {
                Button("Add Preset") {
                    var presets = settings.niri.containerPrimarySpanPresets
                    presets.append(0.5)
                    settings.niri.containerPrimarySpanPresets = presets
                    controller.updateNiriConfig(containerPrimarySpanPresets: settings.niri.containerPrimarySpanPresets)
                }
                Button("Reset Cycle Presets") {
                    settings.niri.containerPrimarySpanPresets = NiriSettings.defaultContainerPrimarySpanPresets
                    controller.updateNiriConfig(containerPrimarySpanPresets: settings.niri.containerPrimarySpanPresets)
                }
            }
            SettingsCaption(localized: "Resize commands cycle through these presets in order. Duplicates are allowed.")
        }
        .id(settings.niri.containerPrimarySpanPresets.count)
    }
}

private struct MonitorNiriSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor

    private var monitorSettings: MonitorNiriSettings {
        settings.niri.settings(for: monitor) ?? MonitorNiriSettings(
            monitorName: monitor.name
        )
    }

    private func updateSetting(_ update: (inout MonitorNiriSettings) -> Void) {
        var ms = monitorSettings
        update(&ms)
        settings.niri.update(ms, for: monitor)
        controller.updateMonitorNiriSettings()
    }

    var body: some View {
        let ms = monitorSettings

        Section("Niri Layout") {
            OverridableSlider(
                label: String(localized: "Visible Containers"),
                value: ms.visibleContainerCount.map { Double($0) },
                globalValue: Double(settings.niri.visibleContainerCount),
                range: 1 ... 5,
                step: 1,
                formatter: { "\(Int($0))" },
                onChange: { newValue in
                    updateSetting { $0.visibleContainerCount = Int(newValue) }
                    settings.niri.defaultContainerPrimarySpan = nil
                    controller.updateNiriConfig(defaultContainerPrimarySpan: settings.niri.defaultContainerPrimarySpan)
                    controller.balanceNiriSizesAllWorkspaces()
                },
                onReset: { updateSetting { $0.visibleContainerCount = nil } }
            )

            OverridableToggle(
                label: String(localized: "Infinite Loop Navigation"),
                value: ms.infiniteLoop,
                globalValue: settings.niri.infiniteLoop,
                onChange: { newValue in updateSetting { $0.infiniteLoop = newValue } },
                onReset: { updateSetting { $0.infiniteLoop = nil } }
            )

            OverridablePicker(
                label: String(localized: "Center Focused Column"),
                value: ms.centerFocusedColumn,
                globalValue: settings.niri.centerFocusedColumn,
                options: CenterFocusedColumn.allCases,
                displayName: { $0.localizedDisplayName },
                onChange: { newValue in updateSetting { $0.centerFocusedColumn = newValue } },
                onReset: { updateSetting { $0.centerFocusedColumn = nil } }
            )

            OverridableToggle(
                label: String(localized: "Always Center Single Column"),
                value: ms.alwaysCenterSingleColumn,
                globalValue: settings.niri.alwaysCenterSingleColumn,
                onChange: { newValue in updateSetting { $0.alwaysCenterSingleColumn = newValue } },
                onReset: { updateSetting { $0.alwaysCenterSingleColumn = nil } }
            )

            SingleWindowFitControls(
                label: String(localized: "Single Window"),
                fit: ms.singleWindowFit ?? settings.niri.singleWindowFit,
                modes: SingleWindowFit.niriModes,
                isOverridden: ms.singleWindowFit != nil,
                onChange: { newValue in updateSetting { $0.singleWindowFit = newValue } },
                onReset: { updateSetting { $0.singleWindowFit = nil } }
            )
        }
    }
}
