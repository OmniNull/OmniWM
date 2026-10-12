// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct DesiredBorderSurface: Equatable {
    var token: WindowToken
    var frame: CGRect
    var config: BorderConfig

    var windowId: Int {
        token.windowId
    }
}

struct DesiredBarSurface: Equatable {
    var monitor: Monitor
    var visible: Bool
    var snapshot: WorkspaceBarSnapshot
    var retainWhileHidden = false
}

struct ParkingEdgeMaskKey: Hashable {
    enum Side: String, Hashable {
        case left
        case right
    }

    let monitorId: Monitor.ID
    let side: Side
}

struct DesiredParkingEdgeMask: Equatable {
    let key: ParkingEdgeMaskKey
    let frame: CGRect
}

struct DesiredSurfaceScene: Equatable {
    var border: DesiredBorderSurface?
    var tabRails: [TabRailInfo] = []
    var tabRailStyle: TabRailStyle = .compact
    var placeholders: [NativeFullscreenPlaceholderUpdate] = []
    var bars: [DesiredBarSurface] = []
    var parkingEdgeMasks: [DesiredParkingEdgeMask] = []
    var niriColumns: [WorkspaceDescriptor.ID: NiriColumnSummary] = [:]

    static let empty = DesiredSurfaceScene()
}
