// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation
import OmniWMIPC

@MainActor @Observable
final class NiriSettings {
    private nonisolated static let defaults = SettingsExport.Niri.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    var resizeStepPercent = NiriSettings.defaults.resizeStepPercent ?? BuiltInSettingsDefaults.niriResizeStepPercent {
        didSet {
            let validated = min(100, max(1, resizeStepPercent))
            if validated != resizeStepPercent {
                resizeStepPercent = validated
                return
            }
            onChange?()
        }
    }

    var containerPrimarySpanPresets = NiriSettings.validatedContainerPrimarySpanPresets(
        NiriSettings.defaults.containerPrimarySpanPresets ?? BuiltInSettingsDefaults
            .niriContainerPrimarySpanPresets
    ) {
        didSet { onChange?() }
    }

    var defaultContainerPrimarySpan = NiriSettings.validatedDefaultContainerPrimarySpan(
        NiriSettings.defaults.defaultContainerPrimarySpan
    ) {
        didSet {
            let validated = NiriSettings.validatedDefaultContainerPrimarySpan(defaultContainerPrimarySpan)
            if validated != defaultContainerPrimarySpan {
                defaultContainerPrimarySpan = validated
                return
            }
            onChange?()
        }
    }

    var visibleContainerCount = NiriSettings.defaults.visibleContainerCount {
        didSet { onChange?() }
    }

    var infiniteLoop = NiriSettings.defaults.infiniteLoop {
        didSet { onChange?() }
    }

    var centerFocusedColumn = NiriSettings.defaults.centerFocusedColumn {
        didSet { onChange?() }
    }

    var alwaysCenterSingleColumn = NiriSettings.defaults.alwaysCenterSingleColumn {
        didSet { onChange?() }
    }

    var singleWindowFit = NiriSettings.defaults.singleWindowFit {
        didSet { onChange?() }
    }

    var edgeGaps = NiriSettings.defaults.edgeGaps ?? true {
        didSet { onChange?() }
    }

    var accordionPadding = NiriSettings.defaults.accordionPadding ?? 30 {
        didSet { onChange?() }
    }

    var accordionAxis = NiriSettings.defaults.accordionAxis ?? .horizontal {
        didSet { onChange?() }
    }

    var monitorOverrides: [MonitorNiriSettings] = [] {
        didSet { onChange?() }
    }

    func export() -> SettingsExport.Niri {
        SettingsExport.Niri(
            visibleContainerCount: visibleContainerCount,
            infiniteLoop: infiniteLoop,
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            singleWindowFit: singleWindowFit,
            containerPrimarySpanPresets: containerPrimarySpanPresets,
            defaultContainerPrimarySpan: defaultContainerPrimarySpan,
            edgeGaps: edgeGaps,
            resizeStepPercent: resizeStepPercent,
            accordionPadding: accordionPadding,
            accordionAxis: accordionAxis
        )
    }

    func apply(_ niri: SettingsExport.Niri, baseline: SettingsExport.Niri) {
        visibleContainerCount = niri.visibleContainerCount
        infiniteLoop = niri.infiniteLoop
        centerFocusedColumn = niri.centerFocusedColumn
        alwaysCenterSingleColumn = niri.alwaysCenterSingleColumn
        singleWindowFit = niri.singleWindowFit
        edgeGaps = niri.edgeGaps ?? baseline.edgeGaps ?? true
        resizeStepPercent = niri.resizeStepPercent ?? baseline.resizeStepPercent ?? BuiltInSettingsDefaults
            .niriResizeStepPercent
        containerPrimarySpanPresets = NiriSettings.validatedContainerPrimarySpanPresets(
            niri.containerPrimarySpanPresets ?? baseline.containerPrimarySpanPresets ?? NiriSettings
                .defaultContainerPrimarySpanPresets
        )
        defaultContainerPrimarySpan = NiriSettings
            .validatedDefaultContainerPrimarySpan(niri.defaultContainerPrimarySpan)
        accordionPadding = NiriSettings.validatedAccordionPadding(
            niri.accordionPadding ?? baseline.accordionPadding ?? 30
        )
        accordionAxis = niri.accordionAxis ?? baseline.accordionAxis ?? .horizontal
    }

    func settings(for monitor: Monitor) -> MonitorNiriSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorOverrides)
    }

    func update(_ settings: MonitorNiriSettings, for monitor: Monitor) {
        MonitorSettingsStore.update(settings, for: monitor, in: &monitorOverrides)
    }

    func remove(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorOverrides)
    }

    func resolved(for monitor: Monitor) -> ResolvedNiriSettings {
        resolved(override: settings(for: monitor))
    }

    private func resolved(override: MonitorNiriSettings?) -> ResolvedNiriSettings {
        return ResolvedNiriSettings(
            visibleContainerCount: override?.visibleContainerCount ?? visibleContainerCount,
            centerFocusedColumn: override?.centerFocusedColumn ?? centerFocusedColumn,
            alwaysCenterSingleColumn: override?.alwaysCenterSingleColumn ?? alwaysCenterSingleColumn,
            singleWindowFit: override?.singleWindowFit ?? singleWindowFit,
            infiniteLoop: override?.infiniteLoop ?? infiniteLoop
        )
    }

    nonisolated static let defaultContainerPrimarySpanPresets: [Double] = BuiltInSettingsDefaults
        .niriContainerPrimarySpanPresets

    static func validatedContainerPrimarySpanPresets(_ presets: [Double]) -> [Double] {
        let result = presets.map { min(1.0, max(0.05, $0)) }
        if result.count < 2 {
            return defaultContainerPrimarySpanPresets
        }
        return result
    }

    static func validatedDefaultContainerPrimarySpan(_ width: Double?) -> Double? {
        guard let width else { return nil }
        return min(1.0, max(0.05, width))
    }

    nonisolated static func validatedAccordionPadding(_ padding: Double) -> Double {
        guard padding.isFinite else { return 30 }
        return min(200, max(0, padding))
    }
}
