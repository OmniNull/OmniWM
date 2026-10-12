// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct NiriCalculationContext {
    let geometry: NiriLayoutGeometry
    let area: WorkingAreaContext
    let primaryGap: CGFloat
    let secondaryGap: CGFloat
    let time: TimeInterval
    let frames: NiriLayoutFrames
    let hiddenPlacementMonitor: HiddenPlacementMonitorContext?
    let hiddenPlacementMonitors: [HiddenPlacementMonitorContext]

    var orientation: Monitor.Orientation {
        geometry.orientation
    }

    init(
        geometry: NiriLayoutGeometry,
        time: TimeInterval,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]
    ) {
        self.geometry = geometry
        area = geometry.resolveWorkingArea()
        (primaryGap, secondaryGap) = geometry.axisGaps()
        self.time = time
        frames = NiriLayoutFrames(area: area, workspaceOffset: 0, orientation: geometry.orientation)
        self.hiddenPlacementMonitor = hiddenPlacementMonitor
        self.hiddenPlacementMonitors = hiddenPlacementMonitors
    }
}

struct NiriViewportSampling {
    let viewOffset: CGFloat
    let settledVisibilityOffset: CGFloat?
    let isSettled: Bool
}

struct NiriViewportSelection {
    let state: ViewportState
    let workspaceId: WorkspaceDescriptor.ID
}

struct NiriContainerLayoutContext {
    let frames: NiriLayoutFrames
    let secondaryGap: CGFloat
    let time: TimeInterval
}

struct NiriColumnLayoutPass {
    let context: NiriCalculationContext
    let viewport: NiriLayoutViewport
    let activeIndex: Int
    let viewPosition: CGFloat
    let selectedNodeId: NodeId?
    let settledContentFrame: CGRect?
}
