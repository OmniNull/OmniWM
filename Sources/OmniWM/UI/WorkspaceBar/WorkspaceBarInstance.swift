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
    private var measuredLengths: [WorkspaceBarIslandSlice: CGFloat] = [:]
    var screenDisplayId: CGDirectDisplayID?

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

    static func splits(
        _ snapshot: WorkspaceBarSnapshot,
        geometry: WorkspaceBarGeometry,
        monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> Bool {
        resolved.notchMode.isSplit
            && snapshot.items.contains(where: \.isFocused)
            && geometry.splitAvailableWidths(monitor: monitor, resolved: resolved) != nil
    }

    static func scratchpadWidth(
        on slice: WorkspaceBarIslandSlice,
        geometry: WorkspaceBarGeometry,
        monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> CGFloat {
        if slice == .secondary {
            geometry.splitAvailableWidths(monitor: monitor, resolved: resolved)?.secondary ?? monitor.frame.width
        } else if resolved.notchMode == .fillLeftOfNotch {
            geometry.frame(fittingLength: 0, monitor: monitor, resolved: resolved).width
        } else {
            geometry.availableWidth(monitor: monitor, resolved: resolved)
        }
    }

    func splitLayout(
        geometry: WorkspaceBarGeometry,
        snapshot: WorkspaceBarSnapshot,
        monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> WorkspaceBarSplitLayout? {
        guard Self.splits(snapshot, geometry: geometry, monitor: monitor, resolved: resolved) else {
            return nil
        }
        return geometry.splitFrame(
            activeWidth: measuredLength(for: snapshot, slice: .active),
            secondaryWidth: snapshot.shellWidgets.contains { $0.island == .secondary }
                ? measuredLength(for: snapshot, slice: .secondary)
                : nil,
            monitor: monitor,
            resolved: resolved
        )
    }

    func measuredLength(for snapshot: WorkspaceBarSnapshot, slice: WorkspaceBarIslandSlice) -> CGFloat {
        if let cached = measuredLengths[slice] {
            return cached
        }
        measurementView.rootView = WorkspaceBarMeasurementView(snapshot: snapshot, slice: slice)
        measurementView.layoutSubtreeIfNeeded()
        let length = snapshot.orientation.isVertical
            ? measurementView.fittingSize.height
            : measurementView.fittingSize.width
        measuredLengths[slice] = length
        return length
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
        guard model.snapshot != snapshot else { return }
        model.snapshot = snapshot
        measuredLengths = [:]
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
        primary.applySettings(resolved: resolved, monitor: monitor)
        secondary?.applySettings(resolved: resolved, monitor: monitor)
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
