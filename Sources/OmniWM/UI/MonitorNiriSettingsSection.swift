// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct MonitorNiriSettingsSection: View {
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
                case .app: .app
                case .custom: .custom
                }
            },
            set: { mode in
                let span: NiriContainerPrimarySpanOverride? = switch mode {
                case .useGlobal: nil
                case .auto: .auto
                case .app: .app
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
                value: ms.visibleContainerCount == nil && ms.fitToVisibleContainerCount == nil
                    ? nil
                    : resolved.fitsVisibleContainerCount ? Double(resolved.visibleContainerCount) : 0,
                globalValue: settings.niri.fitToVisibleContainerCount ? Double(settings.niri.visibleContainerCount) : 0,
                range: 0 ... 5,
                step: 1,
                formatter: { $0 > 0 ? "\(Int($0))" : String(localized: "Off") },
                onChange: { newValue in
                    updateSetting {
                        $0.fitToVisibleContainerCount = newValue > 0
                        if newValue > 0 {
                            $0.visibleContainerCount = Int(newValue)
                        }
                    }
                    if newValue > 0 {
                        controller.rebalanceNiriSizesForVisibleContainerCountChange(on: monitor.id)
                    }
                },
                onReset: {
                    updateSetting {
                        $0.visibleContainerCount = nil
                        $0.fitToVisibleContainerCount = nil
                    }
                }
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

            OverridableSlider(
                label: String(localized: "Peripheral Vision"),
                value: ms.edgePeekPercent,
                globalValue: settings.niri.edgePeekPercent,
                range: 0 ... 10,
                step: 0.5,
                formatter: { $0.formatted(.number.precision(.fractionLength(0 ... 1))) + "%" },
                onChange: { newValue in updateSetting { $0.edgePeekPercent = newValue } },
                onReset: { updateSetting { $0.edgePeekPercent = nil } }
            )

            SettingsCaption(
                localized: "Keeps part of the next window in view at each strip edge that has more windows. Columns and resizes leave room for it unless a window needs more space. A share of the display’s width for horizontal strips or height for vertical strips; at 0%, peeking is off."
            )
        }
        .id("Niri Layout")

        NiriDefaultSpanSettingsSection(allowsGlobal: true, mode: spanMode, percent: spanPercent)
    }
}
