// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class WorkspaceBarInstance {
    let monitorId: Monitor.ID
    private let measurementView: NSHostingView<WorkspaceBarMeasurementView>
    let model: WorkspaceBarModel

    var primary: WorkspaceBarIslandPanel
    var secondary: WorkspaceBarIslandPanel?
    var monitor: Monitor
    private var measuredWidths: [WorkspaceBarMeasurementKey: CGFloat] = [:]
    var statsAnchor: CGPoint?
    var screenDisplayId: CGDirectDisplayID?
    private var uncompactedSnapshot: WorkspaceBarSnapshot?
    private var scratchpadCompactionContext: ScratchpadCompactionContext?
    private var compactedScratchpads: [WorkspaceBarScratchpadItem]?

    init(
        monitor: Monitor,
        primary: WorkspaceBarIslandPanel,
        measurementView: NSHostingView<WorkspaceBarMeasurementView>,
        model: WorkspaceBarModel,
        screenDisplayId: CGDirectDisplayID?
    ) {
        monitorId = monitor.id
        self.monitor = monitor
        self.primary = primary
        self.measurementView = measurementView
        self.model = model
        self.screenDisplayId = screenDisplayId
    }

    private struct WorkspaceBarMeasurementKey: Hashable {
        let slice: WorkspaceBarIslandSlice
        let showsSystemStatsButton: Bool
    }

    struct SplitLayoutResult {
        let layout: WorkspaceBarSplitLayout
        let primaryShowsSystemStatsButton: Bool
        let secondaryShowsSystemStatsButton: Bool
    }

    private struct ScratchpadCompactionContext: Equatable {
        let availableWidth: CGFloat
        let slice: WorkspaceBarIslandSlice
    }

    func splitLayout(
        geometry: WorkspaceBarGeometry,
        snapshot: WorkspaceBarSnapshot,
        monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> SplitLayoutResult? {
        guard resolved.notchMode.isSplit,
              snapshot.items.contains(where: \.isFocused)
        else {
            return nil
        }
        let hasSecondaryContent = !WorkspaceBarIslandSlice.secondary.items(in: snapshot).isEmpty
            || !WorkspaceBarIslandSlice.secondary.scratchpads(in: snapshot).isEmpty
        let activeShowsSystemStatsButton = snapshot.showSystemStatsButton && !hasSecondaryContent
        let secondaryShowsSystemStatsButton = snapshot.showSystemStatsButton && hasSecondaryContent
        guard let layout = geometry.splitFrame(
            activeWidth: measuredWidth(
                for: snapshot,
                slice: .active,
                showsSystemStatsButton: activeShowsSystemStatsButton
            ),
            secondaryWidth: hasSecondaryContent
                ? measuredWidth(
                    for: snapshot,
                    slice: .secondary,
                    showsSystemStatsButton: secondaryShowsSystemStatsButton
                )
                : nil,
            monitor: monitor,
            resolved: resolved
        ) else {
            return nil
        }
        return SplitLayoutResult(
            layout: layout,
            primaryShowsSystemStatsButton: activeShowsSystemStatsButton,
            secondaryShowsSystemStatsButton: secondaryShowsSystemStatsButton
        )
    }

    func measuredWidth(
        for snapshot: WorkspaceBarSnapshot,
        slice: WorkspaceBarIslandSlice,
        showsSystemStatsButton: Bool
    ) -> CGFloat {
        let key = WorkspaceBarMeasurementKey(
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton
        )
        if let cached = measuredWidths[key] {
            return cached
        }
        let width = uncachedMeasuredWidth(
            for: snapshot,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton
        )
        measuredWidths[key] = width
        return width
    }

    func scratchpadCompactedSnapshot(
        _ snapshot: WorkspaceBarSnapshot,
        monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> WorkspaceBarSnapshot {
        guard !snapshot.scratchpads.isEmpty else {
            uncompactedSnapshot = snapshot
            scratchpadCompactionContext = nil
            compactedScratchpads = nil
            return snapshot
        }

        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
        let splitAvailableWidths = geometry.splitAvailableWidths(monitor: monitor, resolved: resolved)
        let usesSplitLayout = resolved.notchMode.isSplit
            && snapshot.items.contains(where: \.isFocused)
            && splitAvailableWidths != nil
        let slice: WorkspaceBarIslandSlice = usesSplitLayout ? .secondary : .all
        let availableWidth = if usesSplitLayout {
            splitAvailableWidths?.secondary ?? monitor.frame.width
        } else if resolved.notchMode == .fillLeftOfNotch {
            geometry.frame(fittingWidth: 0, monitor: monitor, resolved: resolved).width
        } else {
            geometry.availableWidth(monitor: monitor, resolved: resolved)
        }
        let context = ScratchpadCompactionContext(
            availableWidth: availableWidth,
            slice: slice
        )
        if uncompactedSnapshot == snapshot,
           scratchpadCompactionContext == context,
           let compactedScratchpads = compactedScratchpads
        {
            return snapshot.replacingScratchpads(compactedScratchpads)
        }
        uncompactedSnapshot = snapshot
        scratchpadCompactionContext = context
        let showsSystemStatsButton = snapshot.showSystemStatsButton
        let baseSnapshot = snapshot.replacingScratchpads([])
        let baseWidth = uncachedMeasuredWidth(
            for: baseSnapshot,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton
        )
        let hasAdjacentContent = !slice.items(in: baseSnapshot).isEmpty || showsSystemStatsButton
        let scratchpads = WorkspaceBarScratchpadLayout.compactedItems(
            snapshot.scratchpads,
            availableWidth: availableWidth,
            baseWidth: baseWidth,
            barHeight: snapshot.barHeight,
            hasAdjacentContent: hasAdjacentContent
        )
        compactedScratchpads = scratchpads
        return snapshot.replacingScratchpads(scratchpads)
    }

    private func uncachedMeasuredWidth(
        for snapshot: WorkspaceBarSnapshot,
        slice: WorkspaceBarIslandSlice,
        showsSystemStatsButton: Bool
    ) -> CGFloat {
        measurementView.rootView = WorkspaceBarMeasurementView(
            snapshot: snapshot,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton
        )
        measurementView.layoutSubtreeIfNeeded()
        return measurementView.fittingSize.width
    }

    func applyCurrentAppearance() {
        let appearance = NSApplication.shared.appearance
        primary.panel.appearance = appearance
        primary.hostingView.appearance = appearance
        secondary?.panel.appearance = appearance
        secondary?.hostingView.appearance = appearance
        measurementView.appearance = appearance
    }

    func updateSnapshot(_ snapshot: WorkspaceBarSnapshot) {
        if model.snapshot != snapshot {
            model.snapshot = snapshot
            measuredWidths = [:]
        }
    }

    func refreshAppearance(resolved: ResolvedBarSettings) {
        let current = model.snapshot
        let snapshot = WorkspaceBarSnapshot(
            projection: current.projection,
            showLabels: current.showLabels,
            showSystemStatsButton: current.showSystemStatsButton,
            backgroundOpacity: current.backgroundOpacity,
            inactiveIconOpacity: current.inactiveIconOpacity,
            transparentBackground: current.transparentBackground,
            solidBlackBackground: current.solidBlackBackground,
            showItemBackgrounds: current.showItemBackgrounds,
            showAccentHighlights: current.showAccentHighlights,
            barHeight: current.barHeight,
            accentColor: resolved.accentColor,
            textColor: resolved.textColor
        )

        if snapshot != current {
            model.snapshot = snapshot
        }
    }

    func updateMonitor(_ monitor: Monitor, screen: NSScreen?) -> Bool {
        let nextScreenDisplayId = screen?.displayId

        if let currentScreenDisplayId = screenDisplayId,
           nextScreenDisplayId != currentScreenDisplayId
        {
            return false
        }

        if nextScreenDisplayId == nil, screenDisplayId != nil {
            return false
        }

        self.monitor = monitor
        screenDisplayId = nextScreenDisplayId
        primary.panel.targetScreen = screen
        secondary?.panel.targetScreen = screen

        return true
    }

    func applyPanelSettings(resolved: ResolvedBarSettings) {
        primary.applySettings(resolved: resolved)
        secondary?.applySettings(resolved: resolved)
    }

    func surfaceId() -> String {
        "workspace-bar-\(String(describing: monitorId))"
    }

    func secondarySurfaceId() -> String {
        "workspace-bar-secondary-\(String(describing: monitorId))"
    }

    static let surfacePolicy = SurfacePolicy(
        kind: .workspaceBar,
        hitTestPolicy: .interactive,
        capturePolicy: .included,
        suppressesManagedFocusRecovery: false
    )
}
