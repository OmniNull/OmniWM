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

    var isRetained: Bool {
        visible || retainWhileHidden
    }
}

struct DesiredIslandSurface: Equatable {
    var monitor: Monitor
    var fullscreen: Bool
    var navigation: IslandNavigationSnapshot?
}

struct ParkingEdgeMaskKey: Hashable {
    enum Side: String, Hashable {
        case left
        case right
        case top
        case bottom

        var step: Int {
            switch self {
            case .left,
                 .bottom: -1
            case .right,
                 .top: 1
            }
        }

        func frame(in bounds: CGRect) -> CGRect {
            switch self {
            case .left: CGRect(x: bounds.minX, y: bounds.minY, width: 1, height: bounds.height)
            case .right: CGRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height)
            case .top: CGRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1)
            case .bottom: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1)
            }
        }
    }

    let monitorId: Monitor.ID
    let side: Side
}

struct DesiredParkingEdgeMask: Equatable {
    let key: ParkingEdgeMaskKey
    let frame: CGRect
    var navigation: ParkingEdgeNavigation?
}

struct ParkingEdgeNavigation: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let target: WindowToken
    let hoverEnabled: Bool
}

struct DesiredSurfaceScene: Equatable {
    var border: DesiredBorderSurface?
    var tabRails: [TabRailInfo] = []
    var tabRailStyle: TabRailStyle = .compact
    var placeholders: [NativeFullscreenPlaceholderUpdate] = []
    var bars: [DesiredBarSurface] = []
    var islands: [DesiredIslandSurface] = []
    var parkingEdgeMasks: [DesiredParkingEdgeMask] = []
    var niriColumns: [WorkspaceDescriptor.ID: NiriColumnSummary] = [:]

    static let empty = DesiredSurfaceScene()
}
