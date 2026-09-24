// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

enum TabRailOwner: Hashable {
    case niriColumn(NodeId)
    case dwindleTile(DwindleTileId)

    var surfaceIdentifier: String {
        switch self {
        case let .niriColumn(id):
            "niri-column-\(id.uuid.uuidString)"
        case let .dwindleTile(id):
            "dwindle-tile-\(id.uuidString)"
        }
    }
}

struct TabRailTabInfo: Equatable {
    let visualIndex: Int
    let token: WindowToken?
    let windowId: Int?
    let appName: String?
    let title: String?
    let isActive: Bool

    var accessibilityLabel: String {
        let ordinal = String(localized: "Tab \(visualIndex + 1)")
        switch (title?.nilIfEmpty, appName?.nilIfEmpty) {
        case let (title?, appName?):
            return String(localized: "\(ordinal), \(title), \(appName)")
        case let (title?, nil):
            return String(localized: "\(ordinal), \(title)")
        case let (nil, appName?):
            return String(localized: "\(ordinal), \(appName)")
        case (nil, nil):
            return ordinal
        }
    }
}

struct TabRailInfo: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let owner: TabRailOwner
    let plannedSeq: UInt64
    let tileFrame: CGRect
    let visibleTileFrame: CGRect
    let tabCount: Int
    let activeVisualIndex: Int
    let activeWindowId: Int?
    let tabs: [TabRailTabInfo]

    var key: TabRailKey {
        TabRailKey(workspaceId: workspaceId, owner: owner)
    }

    init(
        workspaceId: WorkspaceDescriptor.ID,
        owner: TabRailOwner,
        plannedSeq: UInt64,
        tileFrame: CGRect,
        visibleTileFrame: CGRect? = nil,
        tabCount: Int,
        activeVisualIndex: Int,
        activeWindowId: Int?,
        tabs: [TabRailTabInfo]? = nil
    ) {
        self.workspaceId = workspaceId
        self.owner = owner
        self.plannedSeq = plannedSeq
        self.tileFrame = tileFrame
        self.visibleTileFrame = visibleTileFrame ?? tileFrame
        self.tabCount = max(0, tabCount)
        self.activeVisualIndex = activeVisualIndex
        self.activeWindowId = activeWindowId
        self.tabs = tabs ?? Self.defaultTabs(tabCount: tabCount, activeVisualIndex: activeVisualIndex)
    }

    var normalizedTabs: [TabRailTabInfo] {
        let metadataByIndex = Dictionary(
            tabs.map { ($0.visualIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return Self.defaultTabs(
            tabCount: tabCount,
            activeVisualIndex: activeVisualIndex
        ).map { fallback in
            metadataByIndex[fallback.visualIndex] ?? fallback
        }
    }

    private static func defaultTabs(tabCount: Int, activeVisualIndex: Int) -> [TabRailTabInfo] {
        guard tabCount > 0 else { return [] }
        let clampedActiveVisualIndex = min(max(0, activeVisualIndex), tabCount - 1)
        return (0 ..< tabCount).map { visualIndex in
            TabRailTabInfo(
                visualIndex: visualIndex,
                token: nil,
                windowId: nil,
                appName: nil,
                title: nil,
                isActive: visualIndex == clampedActiveVisualIndex
            )
        }
    }
}

struct TabRailKey: Hashable {
    let workspaceId: WorkspaceDescriptor.ID
    let owner: TabRailOwner
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
