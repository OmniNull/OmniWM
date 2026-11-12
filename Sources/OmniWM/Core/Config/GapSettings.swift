// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation
import OmniWMIPC

@MainActor @Observable
final class GapSettings {
    private nonisolated static let defaults = SettingsExport.Gaps.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    var size = GapSettings.defaults.size {
        didSet { onChange?() }
    }

    var outerGapLeft = GapSettings.defaults.outer.left {
        didSet { onChange?() }
    }

    var outerGapRight = GapSettings.defaults.outer.right {
        didSet { onChange?() }
    }

    var outerGapTop = GapSettings.defaults.outer.top {
        didSet { onChange?() }
    }

    var outerGapBottom = GapSettings.defaults.outer.bottom {
        didSet { onChange?() }
    }

    var fullscreenUsesOuterGaps = GapSettings.defaults.fullscreenUsesOuterGaps {
        didSet { onChange?() }
    }

    var monitorOverrides: [MonitorGapSettings] = [] {
        didSet { onChange?() }
    }

    func export() -> SettingsExport.Gaps {
        let size = self.size
        let outer = SettingsExport.OuterGaps(
            left: outerGapLeft,
            right: outerGapRight,
            top: outerGapTop,
            bottom: outerGapBottom
        )
        return SettingsExport.Gaps(
            size: size,
            fullscreenUsesOuterGaps: fullscreenUsesOuterGaps,
            outer: outer
        )
    }

    func apply(_ gaps: SettingsExport.Gaps) {
        size = gaps.size
        outerGapLeft = gaps.outer.left
        outerGapRight = gaps.outer.right
        outerGapTop = gaps.outer.top
        outerGapBottom = gaps.outer.bottom
        fullscreenUsesOuterGaps = gaps.fullscreenUsesOuterGaps
    }

    func settings(for monitor: Monitor) -> MonitorGapSettings? {
        MonitorSettingsStore.get(for: monitor, in: monitorOverrides)
    }

    func update(_ settings: MonitorGapSettings, for monitor: Monitor) {
        if settings.hasOverrides {
            MonitorSettingsStore.update(settings, for: monitor, in: &monitorOverrides)
        } else {
            MonitorSettingsStore.remove(for: monitor, from: &monitorOverrides)
        }
    }

    func remove(for monitor: Monitor) {
        MonitorSettingsStore.remove(for: monitor, from: &monitorOverrides)
    }

    func resolved(for monitor: Monitor) -> ResolvedGapSettings {
        let override = settings(for: monitor)
        return ResolvedGapSettings(
            innerGap: resolvedInnerGap(override?.innerGap),
            outerGapLeft: CGFloat(override?.outerGapLeft ?? outerGapLeft),
            outerGapRight: CGFloat(override?.outerGapRight ?? outerGapRight),
            outerGapTop: CGFloat(override?.outerGapTop ?? outerGapTop),
            outerGapBottom: CGFloat(override?.outerGapBottom ?? outerGapBottom),
            fullscreenUsesOuterGaps: override?.fullscreenUsesOuterGaps ?? fullscreenUsesOuterGaps
        )
    }

    func resolvedFullscreenUsesOuterGaps(for monitor: Monitor) -> Bool {
        settings(for: monitor)?.fullscreenUsesOuterGaps ?? fullscreenUsesOuterGaps
    }

    func resolvedInnerGap(_ override: Double?) -> CGFloat {
        CGFloat(min(64, max(0, override ?? size)))
    }
}
