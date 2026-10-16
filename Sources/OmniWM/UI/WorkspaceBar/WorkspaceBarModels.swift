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

struct WorkspaceBarShellWidget: Identifiable, Equatable {
    let id: String
    let size: CGSize
    let lane: ShellLane
    var island = WorkspaceBarIslandSlice.all
    var failure: ShellWidgetFailure?
}

struct ShellWidgetFailure: Equatable {
    let message: String
    let source: URL
}

struct WorkspaceBarSnapshot: Equatable {
    let projection: WorkspaceBarProjection
    let showLabels: Bool
    let backgroundOpacity: Double
    let transparentBackground: Bool
    let solidBlackBackground: Bool
    let barHeight: CGFloat
    let orientation: WorkspaceBarOrientation
    let secureInputActive: Bool
    let barFill: ShellThemeColor?
    let barBorder: ShellThemeColor?
    var barShader: ShellBarShader?
    let shellWidgets: [WorkspaceBarShellWidget]

    init(
        projection: WorkspaceBarProjection,
        showLabels: Bool = false,
        backgroundOpacity: Double,
        transparentBackground: Bool = false,
        solidBlackBackground: Bool = false,
        barHeight: CGFloat,
        orientation: WorkspaceBarOrientation = .horizontal,
        secureInputActive: Bool = false,
        barFill: ShellThemeColor? = nil,
        barBorder: ShellThemeColor? = nil,
        barShader: ShellBarShader? = nil,
        shellWidgets: [WorkspaceBarShellWidget] = []
    ) {
        self.projection = projection
        self.showLabels = showLabels
        self.backgroundOpacity = backgroundOpacity
        self.transparentBackground = transparentBackground
        self.solidBlackBackground = solidBlackBackground
        self.barHeight = barHeight
        self.orientation = orientation
        self.secureInputActive = secureInputActive
        self.barFill = barFill
        self.barBorder = barBorder
        self.barShader = barShader
        self.shellWidgets = shellWidgets
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
        case palette(fill: ShellThemeColor, border: ShellThemeColor?)
    }

    var backgroundStyle: BackgroundStyle {
        if solidBlackBackground { return .solidBlack }
        if transparentBackground { return .transparent }
        if let barFill { return .palette(fill: barFill, border: barBorder) }
        return .material
    }

    func replacingShellWidgets(_ shellWidgets: [WorkspaceBarShellWidget]) -> Self {
        Self(
            projection: projection,
            showLabels: showLabels,
            backgroundOpacity: backgroundOpacity,
            transparentBackground: transparentBackground,
            solidBlackBackground: solidBlackBackground,
            barHeight: barHeight,
            orientation: orientation,
            secureInputActive: secureInputActive,
            barFill: barFill,
            barBorder: barBorder,
            barShader: barShader,
            shellWidgets: shellWidgets
        )
    }
}

enum WorkspaceBarIslandSlice: String, CaseIterable, Sendable {
    case all
    case active
    case secondary

    func shellWidgets(in snapshot: WorkspaceBarSnapshot, lane: ShellLane) -> [WorkspaceBarShellWidget] {
        snapshot.shellWidgets.filter { $0.island == self && $0.lane == lane }
    }
}

@MainActor @Observable
final class WorkspaceBarModel {
    var snapshot: WorkspaceBarSnapshot
    var hiddenBarJoinEdge: PopupAttachment.Edge?
    var zones: WorkspaceBarZones?

    init(snapshot: WorkspaceBarSnapshot) {
        self.snapshot = snapshot
    }
}
