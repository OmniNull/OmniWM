// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation
import OmniWMIPC

@MainActor @Observable
final class DwindlePreferences {
    private nonisolated static let defaults = SettingsExport.Dwindle.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    private let gaps: GapSettings

    init(gaps: GapSettings) {
        self.gaps = gaps
    }

    var smartSplit = DwindlePreferences.defaults.smartSplit {
        didSet { onChange?() }
    }

    var defaultSplitRatio = DwindlePreferences.defaults.defaultSplitRatio {
        didSet { onChange?() }
    }

    var splitWidthMultiplier = DwindlePreferences.defaults.splitWidthMultiplier {
        didSet { onChange?() }
    }

    var singleWindowFit = DwindlePreferences.defaults.singleWindowFit {
        didSet { onChange?() }
    }

    var useGlobalGaps = DwindlePreferences.defaults.useGlobalGaps {
        didSet { onChange?() }
    }

    var moveToRootStable = DwindlePreferences.defaults.moveToRootStable {
        didSet { onChange?() }
    }

    var stackIncomingWindows = DwindlePreferences.defaults.stackIncomingWindows {
        didSet { onChange?() }
    }

    var monitorOverrides: [MonitorDwindleSettings] = [] {
        didSet { onChange?() }
    }

    func export() -> SettingsExport.Dwindle {
        SettingsExport.Dwindle(
            smartSplit: smartSplit,
            defaultSplitRatio: defaultSplitRatio,
            splitWidthMultiplier: splitWidthMultiplier,
            singleWindowFit: singleWindowFit,
            useGlobalGaps: useGlobalGaps,
            moveToRootStable: moveToRootStable,
            stackIncomingWindows: stackIncomingWindows
        )
    }

    func apply(_ dwindle: SettingsExport.Dwindle) {
        smartSplit = dwindle.smartSplit
        defaultSplitRatio = dwindle.defaultSplitRatio
        splitWidthMultiplier = dwindle.splitWidthMultiplier
        singleWindowFit = dwindle.singleWindowFit
        useGlobalGaps = dwindle.useGlobalGaps
        moveToRootStable = dwindle.moveToRootStable
        stackIncomingWindows = dwindle.stackIncomingWindows
    }

    func settings(for monitor: Monitor) -> MonitorDwindleSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorOverrides)
    }

    func update(_ settings: MonitorDwindleSettings, for monitor: Monitor) {
        MonitorSettingsStore.update(settings, for: monitor, in: &monitorOverrides)
    }

    func remove(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorOverrides)
    }

    func resolved(for monitor: Monitor) -> ResolvedDwindleSettings {
        resolved(
            override: settings(for: monitor),
            sharedInnerGap: gaps.resolved(for: monitor).innerGap
        )
    }

    private func resolved(
        override: MonitorDwindleSettings?,
        sharedInnerGap: CGFloat
    ) -> ResolvedDwindleSettings {
        let useGlobalGaps = override?.useGlobalGaps ?? self.useGlobalGaps
        return ResolvedDwindleSettings(
            smartSplit: override?.smartSplit ?? smartSplit,
            defaultSplitRatio: CGFloat(override?.defaultSplitRatio ?? defaultSplitRatio),
            splitWidthMultiplier: CGFloat(override?.splitWidthMultiplier ?? splitWidthMultiplier),
            singleWindowFit: override?.singleWindowFit ?? singleWindowFit,
            useGlobalGaps: useGlobalGaps,
            innerGap: useGlobalGaps ? sharedInnerGap : gaps.resolvedInnerGap(override?.innerGap),
            stackIncomingWindows: override?.stackIncomingWindows ?? stackIncomingWindows
        )
    }
}
