// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func innerGap(for monitor: Monitor) -> CGFloat {
        innerGap(for: monitor, scale: backingScaleFactor(for: monitor))
    }

    func innerGap(for monitor: Monitor, scale: CGFloat) -> CGFloat {
        let rawGap = settings.gaps.settings(for: monitor)?.innerGap == nil
            ? CGFloat(workspaceManager.gaps)
            : settings.gaps.resolved(for: monitor).innerGap
        return max(rawGap, borderClearance(scale: scale))
    }

    func innerGap(for workspaceId: WorkspaceDescriptor.ID) -> CGFloat {
        guard let monitor = workspaceManager.monitor(for: workspaceId) else {
            return CGFloat(workspaceManager.gaps)
        }
        return innerGap(for: monitor)
    }

    func resolvedDwindleSettings(for monitor: Monitor) -> ResolvedDwindleSettings {
        resolvedDwindleSettings(for: monitor, scale: backingScaleFactor(for: monitor))
    }

    func resolvedDwindleSettings(for monitor: Monitor, scale: CGFloat) -> ResolvedDwindleSettings {
        let resolved = settings.dwindle.resolved(for: monitor)
        return ResolvedDwindleSettings(
            smartSplit: resolved.smartSplit,
            defaultSplitRatio: resolved.defaultSplitRatio,
            splitWidthMultiplier: resolved.splitWidthMultiplier,
            singleWindowFit: resolved.singleWindowFit,
            useGlobalGaps: resolved.useGlobalGaps,
            innerGap: max(resolved.innerGap, borderClearance(scale: scale)),
            stackIncomingWindows: resolved.stackIncomingWindows
        )
    }

    func layoutFrames(
        for monitor: Monitor,
        scale: CGFloat
    ) -> MonitorLayoutFrames {
        let reservedTopInset = workspaceBarReservedTopInset(for: monitor)
        let gaps = settings.gaps.resolved(for: monitor)
        let menuBarInset = max(0, monitor.frame.maxY - monitor.visibleFrame.maxY)
        let normalizedTop = normalizedTopStrut(
            top: gaps.outerGapTop,
            menuBarInset: menuBarInset,
            reservedTopInset: reservedTopInset
        )
        let rawStruts = Struts(
            left: gaps.outerGapLeft,
            right: gaps.outerGapRight,
            top: normalizedTop,
            bottom: gaps.outerGapBottom
        )
        let clearance = borderClearance(scale: scale)
        let effectiveStruts = Struts(
            left: max(rawStruts.left, clearance),
            right: max(rawStruts.right, clearance),
            top: max(rawStruts.top, clearance),
            bottom: max(rawStruts.bottom, clearance)
        )
        let rawWorkingFrame = computeWorkingArea(
            parentArea: monitor.visibleFrame,
            scale: scale,
            struts: rawStruts
        )
        let workingFrame = computeWorkingArea(
            parentArea: monitor.visibleFrame,
            scale: scale,
            struts: effectiveStruts
        )
        let fullscreenLayoutFrame: CGRect
        let borderSafeFillFrame: CGRect
        if gaps.fullscreenUsesOuterGaps {
            fullscreenLayoutFrame = rawWorkingFrame
            borderSafeFillFrame = workingFrame
        } else {
            (fullscreenLayoutFrame, borderSafeFillFrame) = ungappedFullscreenFrames(
                for: monitor, scale: scale, reservedTopInset: reservedTopInset, clearance: clearance
            )
        }
        return MonitorLayoutFrames(
            workingFrame: workingFrame,
            borderSafeFillFrame: borderSafeFillFrame,
            fullscreenLayoutFrame: fullscreenLayoutFrame
        )
    }

    func niriInteractionGeometry(
        for monitor: Monitor
    ) -> NiriInteractionGeometry {
        niriInteractionGeometry(for: monitor, scale: backingScaleFactor(for: monitor))
    }

    func niriInteractionGeometry(
        for monitor: Monitor,
        scale: CGFloat
    ) -> NiriInteractionGeometry {
        let workingFrame = layoutFrames(for: monitor, scale: scale).workingFrame
        return NiriInteractionGeometry(
            workingFrame: workingFrame,
            innerGap: innerGap(for: monitor, scale: scale),
            scale: scale
        )
    }

    func insetWorkingFrame(for monitor: Monitor) -> CGRect {
        let scale = backingScaleFactor(for: monitor)
        return layoutFrames(for: monitor, scale: scale).workingFrame
    }

    func fullscreenLayoutFrame(for monitor: Monitor) -> CGRect {
        let scale = backingScaleFactor(for: monitor)
        return layoutFrames(for: monitor, scale: scale).fullscreenLayoutFrame
    }

    func borderSafeFillFrame(for monitor: Monitor) -> CGRect {
        let scale = backingScaleFactor(for: monitor)
        return layoutFrames(for: monitor, scale: scale).borderSafeFillFrame
    }

    func backingScaleFactor(for monitor: Monitor) -> CGFloat {
        NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 2.0
    }

    private func borderClearance(scale: CGFloat) -> CGFloat {
        BorderConfig.layoutClearance(
            enabled: settings.borders.enabled,
            width: CGFloat(settings.borders.width),
            scale: scale
        )
    }

    private func workspaceBarReservedTopInset(for monitor: Monitor) -> CGFloat {
        guard settings.workspaceBar.revealModifier == .off else { return 0 }
        let resolved = settings.workspaceBar.resolved(for: monitor)
        return WorkspaceBarGeometry.resolve(
            monitor: monitor,
            resolved: resolved,
            isVisible: isWorkspaceBarConfiguredVisible(on: monitor, resolved: resolved)
        ).reservedTopInset
    }

    private func ungappedFullscreenFrames(
        for monitor: Monitor,
        scale: CGFloat,
        reservedTopInset: CGFloat,
        clearance: CGFloat
    ) -> (layout: CGRect, borderSafe: CGRect) {
        let layout = computeWorkingArea(
            parentArea: monitor.visibleFrame,
            scale: scale,
            struts: Struts(top: reservedTopInset)
        )
        let borderSafe = computeWorkingArea(
            parentArea: monitor.visibleFrame,
            scale: scale,
            struts: Struts(
                left: clearance,
                right: clearance,
                top: max(reservedTopInset, clearance),
                bottom: clearance
            )
        )
        return (layout, borderSafe)
    }
}
