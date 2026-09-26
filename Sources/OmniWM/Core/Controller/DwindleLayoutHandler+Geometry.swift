// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    func geometryContext(
        monitor: LayoutMonitorSnapshot,
        settings: ResolvedDwindleSettings
    ) -> DwindleAnimationGeometryContext {
        DwindleAnimationGeometryContext(
            monitorId: monitor.monitorId,
            displayId: monitor.displayId,
            workingFrame: monitor.workingFrame,
            borderSafeFillFrame: monitor.borderSafeFillFrame,
            fullscreenLayoutFrame: monitor.fullscreenLayoutFrame,
            scale: monitor.scale,
            settings: settings,
            tabRailWidth: (controller?.tabRailStyle ?? .compact).reservedWidth
        )
    }

    func geometryContext(
        monitor: Monitor,
        settings: ResolvedDwindleSettings
    ) -> DwindleAnimationGeometryContext? {
        guard let controller else { return nil }
        return geometryContext(
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            settings: settings
        )
    }

    func applyResolvedSettings(
        _ settings: ResolvedDwindleSettings,
        to engine: DwindleLayoutEngine
    ) {
        engine.settings.smartSplit = settings.smartSplit
        engine.settings.defaultSplitRatio = settings.defaultSplitRatio
        engine.settings.splitWidthMultiplier = settings.splitWidthMultiplier
        engine.settings.singleWindowFit = settings.singleWindowFit
        engine.settings.innerGap = settings.innerGap
        engine.settings.stackIncomingWindows = settings.stackIncomingWindows
        engine.tabRailWidth = (controller?.tabRailStyle ?? .compact).reservedWidth
    }

    func calculationSettings(
        _ resolved: ResolvedDwindleSettings,
        from engine: DwindleLayoutEngine
    ) -> DwindleSettings {
        var settings = engine.settings
        settings.smartSplit = resolved.smartSplit
        settings.defaultSplitRatio = resolved.defaultSplitRatio
        settings.splitWidthMultiplier = resolved.splitWidthMultiplier
        settings.singleWindowFit = resolved.singleWindowFit
        settings.innerGap = resolved.innerGap
        settings.stackIncomingWindows = resolved.stackIncomingWindows
        return settings
    }
}
