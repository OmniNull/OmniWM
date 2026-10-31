// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
    @State private var windowTilingSettingsProbe = WindowTilingSettingsProbe()

    var body: some View {
        let spanMode = Binding<NiriDefaultSpanSettingsSection.Mode>(
            get: { settings.niri.defaultContainerPrimarySpan == nil ? .auto : .custom },
            set: { mode in
                settings
                    .niri
                    .defaultContainerPrimarySpan = mode == .auto ? nil :
                    (settings.niri.defaultContainerPrimarySpan ?? 0.5)
                controller.updateNiriConfig(defaultContainerPrimarySpan: settings.niri.defaultContainerPrimarySpan)
            }
        )
        let defaultContainerPrimarySpanPercent = Binding(
            get: { Int(((settings.niri.defaultContainerPrimarySpan ?? 0.5) * 100).rounded()) },
            set: { newPercent in
                settings.niri.defaultContainerPrimarySpan = Double(min(100, max(5, newPercent))) / 100.0
                controller.updateNiriConfig(defaultContainerPrimarySpan: settings.niri.defaultContainerPrimarySpan)
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
            .id("Visible Containers")
            .onChange(of: settings.niri.visibleContainerCount) { _, newValue in
                controller.updateNiriConfig(visibleContainerCount: newValue)
                controller.rebalanceNiriSizesForVisibleContainerCountChange()
            }

            Toggle("Infinite Loop Navigation", isOn: Bindable(settings.niri).infiniteLoop)
                .id("Infinite Loop Navigation")
                .onChange(of: settings.niri.infiniteLoop) { _, newValue in
                    controller.updateNiriConfig(infiniteLoop: newValue)
                }

            Picker("Center Focused Column", selection: Bindable(settings.niri).centerFocusedColumn) {
                ForEach(CenterFocusedColumn.allCases, id: \.self) { mode in
                    Text(mode.localizedDisplayName).tag(mode)
                }
            }
            .id("Center Focused Column")
            .onChange(of: settings.niri.centerFocusedColumn) { _, newValue in
                controller.updateNiriConfig(centerFocusedColumn: newValue)
            }

            Toggle("Always Center Single Column", isOn: Bindable(settings.niri).alwaysCenterSingleColumn)
                .id("Always Center Single Column")
                .onChange(of: settings.niri.alwaysCenterSingleColumn) { _, newValue in
                    controller.updateNiriConfig(alwaysCenterSingleColumn: newValue)
                }

            Toggle("Focus Clicked Windows Without Scrolling", isOn: Bindable(settings.focus).clickFocusWithoutScrolling)
                .id("Focus Clicked Windows Without Scrolling")

            SettingsCaption(
                localized: "A left click on a partially visible window focuses it without moving the viewport. Keyboard navigation, gestures, Cmd-Tab, and the Dock still scroll windows into view. Has no effect when Center Focused Column is Always."
            )

            Toggle("Allow Overscroll", isOn: Bindable(settings.niri).allowOverscroll)
                .id("Allow Overscroll")
                .onChange(of: settings.niri.allowOverscroll) { _, _ in
                    controller.updateNiriConfig(edgeOverscroll: settings.niri.edgeOverscroll)
                }

            SettingsSliderRow(
                label: String(localized: "Overscroll Visible Strip"),
                value: Binding(
                    get: { Double(settings.niri.overscrollVisibleStripPercent) },
                    set: { settings.niri.overscrollVisibleStripPercent = Int($0) }
                ),
                range: 1 ... 100,
                step: 1,
                valueText: "\(settings.niri.overscrollVisibleStripPercent)%",
                valueWidth: 48
            )
            .id("Overscroll Visible Strip")
            .disabled(!settings.niri.allowOverscroll)
            .onChange(of: settings.niri.overscrollVisibleStripPercent) { _, _ in
                controller.updateNiriConfig(edgeOverscroll: settings.niri.edgeOverscroll)
            }
            SettingsCaption(
                localized: "Scroll past the first or last container to expose the desktop. The visible strip is a percentage of the edge container's primary span, capped at the viewport span."
            )

            Toggle("Gaps at Screen Edges", isOn: Bindable(settings.niri).edgeGaps)
                .id("Gaps at Screen Edges")
                .onChange(of: settings.niri.edgeGaps) { _, _ in
                    controller.updateMonitorGapSettings()
                }

            Toggle(
                "Stack Moved Window Into Adjacent Column",
                isOn: Bindable(settings.niri).moveWindowStacksIntoColumn
            )
            .id("Stack Moved Window Into Adjacent Column")

            Toggle("Shrink Columns to Fit", isOn: Bindable(settings.niri).shrinkToFit)
                .id("Shrink Columns to Fit")
                .onChange(of: settings.niri.shrinkToFit) { _, newValue in
                    controller.updateNiriConfig(shrinkToFit: newValue)
                }
            SettingsCaption(
                localized: "Keyboard resizing also resizes the other visible columns to fill the view. If a window can't shrink to its share, resize again."
            )

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

            LabeledContent("Resize Increment") {
                HStack {
                    TextField("Resize Increment", value: Bindable(settings.niri).resizeStepPercent, format: .number)
                        .id("Resize Increment")
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 48)
                        .multilineTextAlignment(.trailing)
                    Text("%")
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Natural Window Drag & Drop", isOn: Bindable(settings.niri).naturalWindowDrag)
                .id("Natural Window Drag & Drop")
                .onChange(of: settings.niri.naturalWindowDrag) {
                    controller.applyNaturalWindowDragSettings()
                }
                .onAppear(perform: windowTilingSettingsProbe.refresh)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    windowTilingSettingsProbe.refresh()
                }

            SettingsCaption(
                localized: "Drag a tiled window by its title bar to move its Niri column. Rest on another window and the windows slide over to make room; near a screen edge, a narrow gap shows where it will land, and holding the pointer at the edge scrolls. Release to drop it. Off: title-bar drags snap back."
            )

            if settings.niri.naturalWindowDrag, !windowTilingSettingsProbe.enabledSettings.isEmpty {
                windowTilingNote
            }

            Picker(
                "Left Mouse Natural Window Drag Modifier",
                selection: Bindable(settings.niri).naturalWindowDragModifier
            ) {
                ForEach(MouseMoveModifierKey.allCases, id: \.self) { key in
                    Text(key.localizedDisplayName).tag(key)
                }
            }
            .id("Left Mouse Natural Window Drag Modifier")
            .disabled(!settings.niri.naturalWindowDrag)
            .onChange(of: settings.niri.naturalWindowDragModifier) {
                controller.applyNaturalWindowDragSettings()
            }

            SettingsCaption(
                localized: "Hold this modifier while dragging a title bar to stack the window onto the one under the pointer. That column makes room where the window will land; over tabbed windows it lands as a new tab. When it matches the Left Mouse Move Modifier, it replaces that move in Niri. Choose Off to never stack."
            )

            if settings.niri.naturalWindowDrag,
               settings.niri.naturalWindowDragModifier.cgEventFlags?.contains(.maskCommand) == true
            {
                SettingsCaption(
                    localized: "macOS also uses Command-drag to move a window behind others without bringing it to the front."
                )
            }
        }
        .id("Niri Layout")

        NiriDefaultSpanSettingsSection(
            allowsGlobal: false,
            mode: spanMode,
            percent: defaultContainerPrimarySpanPercent
        )

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
                .id("Add Preset")
                Button("Reset Cycle Presets") {
                    settings.niri.containerPrimarySpanPresets = NiriSettings.defaultContainerPrimarySpanPresets
                    controller.updateNiriConfig(containerPrimarySpanPresets: settings.niri.containerPrimarySpanPresets)
                }
                .id("Reset Cycle Presets")
            }
            SettingsCaption(localized: "Span-cycling commands use these presets in order. Duplicates are allowed.")
        }
        .id(settings.niri.containerPrimarySpanPresets.count)
    }
}

private extension GlobalNiriSettingsSection {
    var windowTilingNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "macOS window tiling interferes with dragging. Turn off these settings in Desktop & Dock:",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(windowTilingSettingsProbe.enabledSettings, id: \.preferenceKey) { setting in
                Text(verbatim: "• \(setting.localizedName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Open Desktop & Dock Settings", action: windowTilingSettingsProbe.openDesktopAndDockSettings)
                .accessibilityHint("Opens macOS Desktop & Dock settings, where window tiling can be turned off.")
        }
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
        let resolved = settings.niri.resolved(for: monitor)
        let effectiveSpan = resolved.defaultContainerPrimarySpan ?? 1.0 / Double(resolved.visibleContainerCount)
        let spanMode = Binding<NiriDefaultSpanSettingsSection.Mode>(
            get: {
                switch monitorSettings.defaultContainerPrimarySpan {
                case nil: .useGlobal
                case .auto: .auto
                case .custom: .custom
                }
            },
            set: { mode in
                let span: NiriContainerPrimarySpanOverride? = switch mode {
                case .useGlobal: nil
                case .auto: .auto
                case .custom: .custom(effectiveSpan)
                }
                updateSetting { $0.defaultContainerPrimarySpan = span }
            }
        )
        let spanPercent = Binding(
            get: { Int((effectiveSpan * 100).rounded()) },
            set: { percent in
                updateSetting {
                    $0.defaultContainerPrimarySpan = .custom(Double(min(100, max(5, percent))) / 100.0)
                }
            }
        )

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
                    controller.rebalanceNiriSizesForVisibleContainerCountChange(on: monitor.id)
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

            OverridableToggle(
                label: String(localized: "Allow Overscroll"),
                value: ms.allowOverscroll,
                globalValue: settings.niri.allowOverscroll,
                onChange: { newValue in updateSetting { $0.allowOverscroll = newValue } },
                onReset: { updateSetting { $0.allowOverscroll = nil } }
            )

            OverridableSlider(
                label: String(localized: "Overscroll Visible Strip"),
                value: ms.overscrollVisibleStripPercent.map(Double.init),
                globalValue: Double(settings.niri.overscrollVisibleStripPercent),
                range: 1 ... 100,
                step: 1,
                formatter: { "\(Int($0))%" },
                onChange: { newValue in updateSetting { $0.overscrollVisibleStripPercent = Int(newValue) } },
                onReset: { updateSetting { $0.overscrollVisibleStripPercent = nil } }
            )
            .disabled(!(ms.allowOverscroll ?? settings.niri.allowOverscroll))

            SingleWindowFitControls(
                label: String(localized: "Single Window"),
                fit: ms.singleWindowFit ?? settings.niri.singleWindowFit,
                modes: SingleWindowFit.niriModes,
                isOverridden: ms.singleWindowFit != nil,
                onChange: { newValue in updateSetting { $0.singleWindowFit = newValue } },
                onReset: { updateSetting { $0.singleWindowFit = nil } }
            )
        }
        .id("Niri Layout")

        NiriDefaultSpanSettingsSection(allowsGlobal: true, mode: spanMode, percent: spanPercent)
    }
}

private struct NiriDefaultSpanSettingsSection: View {
    enum Mode {
        case useGlobal
        case auto
        case custom
    }

    let allowsGlobal: Bool
    @Binding var mode: Mode
    @Binding var percent: Int

    var body: some View {
        Section("Default New Container Primary Span") {
            Picker("Span Mode", selection: $mode) {
                if allowsGlobal {
                    Text("Use Global").tag(Mode.useGlobal)
                }
                Text("Auto").tag(Mode.auto)
                Text("Custom").tag(Mode.custom)
            }
            .id("Span Mode")
            .pickerStyle(.segmented)
            .frame(maxWidth: allowsGlobal ? 320 : 220)

            if mode == .custom {
                LabeledContent("Custom Span") {
                    HStack {
                        TextField("Custom Span", value: $percent, format: .number)
                            .id("Custom Span")
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                        Text("%")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            switch mode {
            case .useGlobal:
                SettingsCaption(localized: "Follows the span setting for All Displays.")
            case .auto:
                SettingsCaption(localized: "Auto divides the primary axis by the Visible Containers setting.")
            case .custom:
                SettingsCaption(
                    localized: "New or claimed containers start at this primary span until you resize them."
                )
            }
        }
        .id("Default New Container Primary Span")
    }
}
