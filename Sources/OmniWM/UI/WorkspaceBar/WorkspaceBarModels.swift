// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Observation

struct WorkspaceBarItem: Identifiable, Equatable {
    let id: WorkspaceDescriptor.ID
    let name: String
    let rawName: String
    let isFocused: Bool
    let tiledWindows: [WorkspaceBarWindowItem]
    let floatingWindows: [WorkspaceBarWindowItem]

    var windows: [WorkspaceBarWindowItem] {
        tiledWindows + floatingWindows
    }
}

struct WorkspaceBarProjection: Equatable {
    let items: [WorkspaceBarItem]
    let scratchpads: [WorkspaceBarScratchpadItem]
}

struct WorkspaceBarWindowItem: Identifiable, Equatable, @unchecked Sendable {
    let id: WindowToken
    let handle: WindowHandle
    let windowId: Int
    let appName: String
    let bundleId: String?
    let icon: NSImage?
    let isFocused: Bool
    let windowCount: Int
    let hiddenWindowCount: Int
    let allWindows: [WorkspaceBarWindowInfo]

    var isAppHidden: Bool {
        hiddenWindowCount == windowCount
    }

    var hasHiddenWindows: Bool {
        hiddenWindowCount > 0
    }

    static func == (lhs: WorkspaceBarWindowItem, rhs: WorkspaceBarWindowItem) -> Bool {
        lhs.id == rhs.id
            && lhs.handle === rhs.handle
            && lhs.windowId == rhs.windowId
            && lhs.appName == rhs.appName
            && lhs.bundleId == rhs.bundleId
            && lhs.icon === rhs.icon
            && lhs.isFocused == rhs.isFocused
            && lhs.windowCount == rhs.windowCount
            && lhs.hiddenWindowCount == rhs.hiddenWindowCount
            && lhs.allWindows == rhs.allWindows
    }
}

struct WorkspaceBarWindowInfo: Identifiable, Equatable, @unchecked Sendable {
    let id: WindowToken
    let handle: WindowHandle
    let windowId: Int
    let title: String
    let isFocused: Bool
    let isAppHidden: Bool
}

enum WorkspaceBarScratchpadPresentation: Equatable {
    case expanded
    case compact
}

struct WorkspaceBarScratchpadItem: Identifiable, Equatable {
    let index: Int
    let label: String?
    let windows: [WorkspaceBarWindowItem]
    let isVisible: Bool
    let isRevealed: Bool
    let presentation: WorkspaceBarScratchpadPresentation

    init(
        index: Int,
        label: String?,
        windows: [WorkspaceBarWindowItem],
        isVisible: Bool,
        isRevealed: Bool? = nil,
        presentation: WorkspaceBarScratchpadPresentation = .expanded
    ) {
        self.index = index
        self.label = label
        self.windows = windows
        self.isVisible = isVisible
        self.isRevealed = isRevealed ?? isVisible
        self.presentation = presentation
    }

    var id: Int {
        index
    }

    var name: String {
        label ?? String(index)
    }

    var isFocused: Bool {
        windows.contains(where: \.isFocused)
    }

    var windowCount: Int {
        windows.reduce(0) { $0 + $1.windowCount }
    }

    func presented(as presentation: WorkspaceBarScratchpadPresentation) -> Self {
        Self(
            index: index,
            label: label,
            windows: windows,
            isVisible: isVisible,
            isRevealed: isRevealed,
            presentation: presentation
        )
    }
}

struct WorkspaceBarSnapshot: Equatable {
    let projection: WorkspaceBarProjection
    let showLabels: Bool
    let showSystemStatsButton: Bool
    let backgroundOpacity: Double
    let inactiveIconOpacity: Double?
    let transparentBackground: Bool
    let solidBlackBackground: Bool
    let showItemBackgrounds: Bool
    let showAccentHighlights: Bool
    let barHeight: CGFloat
    let accentColor: SettingsColor?
    let textColor: SettingsColor?

    init(
        projection: WorkspaceBarProjection,
        showLabels: Bool,
        showSystemStatsButton: Bool,
        backgroundOpacity: Double,
        inactiveIconOpacity: Double? = nil,
        transparentBackground: Bool = false,
        solidBlackBackground: Bool = false,
        showItemBackgrounds: Bool = true,
        showAccentHighlights: Bool = true,
        barHeight: CGFloat,
        accentColor: SettingsColor?,
        textColor: SettingsColor?
    ) {
        self.projection = projection
        self.showLabels = showLabels
        self.showSystemStatsButton = showSystemStatsButton
        self.backgroundOpacity = backgroundOpacity
        self.inactiveIconOpacity = inactiveIconOpacity
        self.transparentBackground = transparentBackground
        self.solidBlackBackground = solidBlackBackground
        self.showItemBackgrounds = showItemBackgrounds
        self.showAccentHighlights = showAccentHighlights
        self.barHeight = barHeight
        self.accentColor = accentColor
        self.textColor = textColor
    }

    var items: [WorkspaceBarItem] {
        projection.items
    }

    var scratchpads: [WorkspaceBarScratchpadItem] {
        projection.scratchpads
    }

    enum BackgroundStyle: Equatable {
        case transparent
        case solidBlack
        case material
    }

    var backgroundStyle: BackgroundStyle {
        if transparentBackground { return .transparent }
        if solidBlackBackground { return .solidBlack }
        return .material
    }

    var showsBackground: Bool {
        backgroundStyle != .transparent
    }

    func replacingScratchpads(_ scratchpads: [WorkspaceBarScratchpadItem]) -> Self {
        Self(
            projection: WorkspaceBarProjection(items: items, scratchpads: scratchpads),
            showLabels: showLabels,
            showSystemStatsButton: showSystemStatsButton,
            backgroundOpacity: backgroundOpacity,
            inactiveIconOpacity: inactiveIconOpacity,
            transparentBackground: transparentBackground,
            solidBlackBackground: solidBlackBackground,
            showItemBackgrounds: showItemBackgrounds,
            showAccentHighlights: showAccentHighlights,
            barHeight: barHeight,
            accentColor: accentColor,
            textColor: textColor
        )
    }
}

enum WorkspaceBarIslandSlice: Hashable {
    case all
    case active
    case secondary

    func items(in snapshot: WorkspaceBarSnapshot) -> [WorkspaceBarItem] {
        switch self {
        case .all: snapshot.items
        case .active: snapshot.items.filter(\.isFocused)
        case .secondary: snapshot.items.filter { !$0.isFocused }
        }
    }

    func scratchpads(in snapshot: WorkspaceBarSnapshot) -> [WorkspaceBarScratchpadItem] {
        self == .active ? [] : snapshot.scratchpads
    }
}

@MainActor @Observable
final class WorkspaceBarModel {
    var snapshot: WorkspaceBarSnapshot
    var presentedWindowList: WindowToken?

    init(snapshot: WorkspaceBarSnapshot) {
        self.snapshot = snapshot
    }
}
