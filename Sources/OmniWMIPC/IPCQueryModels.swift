// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

public enum IPCQueryName: String, Codable, CaseIterable, Equatable, Sendable {
    case workspaceBar = "workspace-bar"
    case activeWorkspace = "active-workspace"
    case focusedMonitor = "focused-monitor"
    case apps
    case focusedWindow = "focused-window"
    case windows
    case workspaces
    case displays
    case rules
    case ruleActions = "rule-actions"
    case queries
    case commands
    case subscriptions
    case capabilities
    case metrics
}

public struct IPCQuerySelectors: Codable, Equatable, Sendable {
    public private(set) var window: String?
    public private(set) var workspace: String?
    public private(set) var display: String?
    public private(set) var focused: Bool?
    public private(set) var visible: Bool?
    public private(set) var floating: Bool?
    public private(set) var scratchpad: Bool?
    public private(set) var app: String?
    public private(set) var bundleId: String?
    public private(set) var current: Bool?
    public private(set) var main: Bool?

    public init(
        window: String? = nil,
        workspace: String? = nil,
        display: String? = nil,
        focused: Bool? = nil,
        visible: Bool? = nil,
        floating: Bool? = nil,
        scratchpad: Bool? = nil,
        app: String? = nil,
        bundleId: String? = nil,
        current: Bool? = nil,
        main: Bool? = nil
    ) {
        self.window = window
        self.workspace = workspace
        self.display = display
        self.focused = focused
        self.visible = visible
        self.floating = floating
        self.scratchpad = scratchpad
        self.app = app
        self.bundleId = bundleId
        self.current = current
        self.main = main
    }

    public var providedSelectorNames: [IPCQuerySelectorName] {
        var names: [IPCQuerySelectorName] = []
        if window != nil { names.append(.window) }
        if workspace != nil { names.append(.workspace) }
        if display != nil { names.append(.display) }
        if focused != nil { names.append(.focused) }
        if visible != nil { names.append(.visible) }
        if floating != nil { names.append(.floating) }
        if scratchpad != nil { names.append(.scratchpad) }
        if app != nil { names.append(.app) }
        if bundleId != nil { names.append(.bundleId) }
        if current != nil { names.append(.current) }
        if main != nil { names.append(.main) }
        return names
    }

    public func setting(_ selector: IPCQuerySelectorName, value: String? = nil) -> IPCQuerySelectors {
        var selectors = self
        switch selector {
        case .window:
            selectors.window = value
        case .workspace:
            selectors.workspace = value
        case .display:
            selectors.display = value
        case .focused:
            selectors.focused = true
        case .visible:
            selectors.visible = true
        case .floating:
            selectors.floating = true
        case .scratchpad:
            selectors.scratchpad = true
        case .app:
            selectors.app = value
        case .bundleId:
            selectors.bundleId = value
        case .current:
            selectors.current = true
        case .main:
            selectors.main = true
        }
        return selectors
    }
}

public struct IPCQueryRequest: Codable, Equatable, Sendable {
    public let name: IPCQueryName
    public let selectors: IPCQuerySelectors
    public let fields: [String]

    public init(
        name: IPCQueryName,
        selectors: IPCQuerySelectors = IPCQuerySelectors(),
        fields: [String] = []
    ) {
        self.name = name
        self.selectors = selectors
        self.fields = fields
    }
}

public struct IPCActiveWorkspaceQueryResult: Codable, Equatable, Sendable {
    public let display: IPCDisplayRef?
    public let workspace: IPCWorkspaceRef?
    public let focusedApp: IPCAppRef?

    public init(display: IPCDisplayRef?, workspace: IPCWorkspaceRef?, focusedApp: IPCAppRef?) {
        self.display = display
        self.workspace = workspace
        self.focusedApp = focusedApp
    }
}

public struct IPCFocusedMonitorQueryResult: Codable, Equatable, Sendable {
    public let display: IPCDisplayRef?
    public let activeWorkspace: IPCWorkspaceRef?

    public init(display: IPCDisplayRef?, activeWorkspace: IPCWorkspaceRef?) {
        self.display = display
        self.activeWorkspace = activeWorkspace
    }
}

public struct IPCManagedAppSummary: Codable, Equatable, Sendable {
    public let bundleId: String
    public let appName: String
    public let windowSize: IPCSize

    public init(bundleId: String, appName: String, windowSize: IPCSize) {
        self.bundleId = bundleId
        self.appName = appName
        self.windowSize = windowSize
    }
}

public struct IPCAppsQueryResult: Codable, Equatable, Sendable {
    public let apps: [IPCManagedAppSummary]

    public init(apps: [IPCManagedAppSummary]) {
        self.apps = apps
    }
}

public struct IPCFocusedWindowSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let pid: Int32?
    public let workspace: IPCWorkspaceRef?
    public let display: IPCDisplayRef?
    public let app: IPCAppRef?
    public let title: String?
    public let frame: IPCRect?
    public let isFullscreen: Bool?

    public init(
        id: String,
        pid: Int32? = nil,
        workspace: IPCWorkspaceRef?,
        display: IPCDisplayRef?,
        app: IPCAppRef?,
        title: String?,
        frame: IPCRect?,
        isFullscreen: Bool? = nil
    ) {
        self.id = id
        self.pid = pid
        self.workspace = workspace
        self.display = display
        self.app = app
        self.title = title
        self.frame = frame
        self.isFullscreen = isFullscreen
    }
}

public struct IPCFocusedWindowQueryResult: Codable, Equatable, Sendable {
    public let window: IPCFocusedWindowSnapshot?

    public init(window: IPCFocusedWindowSnapshot?) {
        self.window = window
    }
}

public struct IPCWindowQuerySnapshot: Codable, Equatable, Sendable {
    public let id: String?
    public let pid: Int32?
    public let windowId: Int?
    public let workspace: IPCWorkspaceRef?
    public let display: IPCDisplayRef?
    public let app: IPCAppRef?
    public let title: String?
    public let frame: IPCRect?
    public let mode: IPCWindowMode?
    public let layoutReason: IPCLayoutReason?
    public let manualOverride: IPCManualWindowOverride?
    public let isFocused: Bool?
    public let isFullscreen: Bool?
    public let isVisible: Bool?
    public let isAppHidden: Bool?
    public let isScratchpad: Bool?
    public let scratchpadIndex: Int?
    public let hiddenReason: IPCHiddenReason?
    public let columnIndex: Int?

    public init(
        id: String? = nil,
        pid: Int32? = nil,
        windowId: Int? = nil,
        workspace: IPCWorkspaceRef? = nil,
        display: IPCDisplayRef? = nil,
        app: IPCAppRef? = nil,
        title: String? = nil,
        frame: IPCRect? = nil,
        mode: IPCWindowMode? = nil,
        layoutReason: IPCLayoutReason? = nil,
        manualOverride: IPCManualWindowOverride? = nil,
        isFocused: Bool? = nil,
        isFullscreen: Bool? = nil,
        isVisible: Bool? = nil,
        isAppHidden: Bool? = nil,
        isScratchpad: Bool? = nil,
        scratchpadIndex: Int? = nil,
        hiddenReason: IPCHiddenReason? = nil,
        columnIndex: Int? = nil
    ) {
        self.id = id
        self.pid = pid
        self.windowId = windowId
        self.workspace = workspace
        self.display = display
        self.app = app
        self.title = title
        self.frame = frame
        self.mode = mode
        self.layoutReason = layoutReason
        self.manualOverride = manualOverride
        self.isFocused = isFocused
        self.isFullscreen = isFullscreen
        self.isVisible = isVisible
        self.isAppHidden = isAppHidden
        self.isScratchpad = isScratchpad
        self.scratchpadIndex = scratchpadIndex
        self.hiddenReason = hiddenReason
        self.columnIndex = columnIndex
    }
}

public struct IPCWindowsQueryResult: Codable, Equatable, Sendable {
    public let windows: [IPCWindowQuerySnapshot]

    public init(windows: [IPCWindowQuerySnapshot]) {
        self.windows = windows
    }
}

public struct IPCWorkspaceColumn: Codable, Equatable, Sendable {
    public let index: Int
    public let viewport: IPCColumnViewport

    public init(index: Int, viewport: IPCColumnViewport) {
        self.index = index
        self.viewport = viewport
    }
}

public struct IPCWorkspaceQuerySnapshot: Codable, Equatable, Sendable {
    public let id: String?
    public let rawName: String?
    public let displayName: String?
    public let number: Int?
    public let layout: IPCWorkspaceLayout?
    public let display: IPCDisplayRef?
    public let isFocused: Bool?
    public let isVisible: Bool?
    public let isCurrent: Bool?
    public let counts: IPCWorkspaceWindowCounts?
    public let focusedWindowId: String?
    public let columns: [IPCWorkspaceColumn]?

    public init(
        id: String? = nil,
        rawName: String? = nil,
        displayName: String? = nil,
        number: Int? = nil,
        layout: IPCWorkspaceLayout? = nil,
        display: IPCDisplayRef? = nil,
        isFocused: Bool? = nil,
        isVisible: Bool? = nil,
        isCurrent: Bool? = nil,
        counts: IPCWorkspaceWindowCounts? = nil,
        focusedWindowId: String? = nil,
        columns: [IPCWorkspaceColumn]? = nil
    ) {
        self.id = id
        self.rawName = rawName
        self.displayName = displayName
        self.number = number
        self.layout = layout
        self.display = display
        self.isFocused = isFocused
        self.isVisible = isVisible
        self.isCurrent = isCurrent
        self.counts = counts
        self.focusedWindowId = focusedWindowId
        self.columns = columns
    }
}

public struct IPCWorkspacesQueryResult: Codable, Equatable, Sendable {
    public let workspaces: [IPCWorkspaceQuerySnapshot]

    public init(workspaces: [IPCWorkspaceQuerySnapshot]) {
        self.workspaces = workspaces
    }
}

public struct IPCDisplayQuerySnapshot: Codable, Equatable, Sendable {
    public let id: String?
    public let name: String?
    public let isMain: Bool?
    public let isCurrent: Bool?
    public let frame: IPCRect?
    public let visibleFrame: IPCRect?
    public let hasNotch: Bool?
    public let orientation: IPCDisplayOrientation?
    public let innerGap: Double?
    public let outerGapLeft: Double?
    public let outerGapRight: Double?
    public let outerGapTop: Double?
    public let outerGapBottom: Double?
    public let fullscreenUsesOuterGaps: Bool?
    public let activeWorkspace: IPCWorkspaceRef?

    public init(
        id: String? = nil,
        name: String? = nil,
        isMain: Bool? = nil,
        isCurrent: Bool? = nil,
        frame: IPCRect? = nil,
        visibleFrame: IPCRect? = nil,
        hasNotch: Bool? = nil,
        orientation: IPCDisplayOrientation? = nil,
        innerGap: Double? = nil,
        outerGapLeft: Double? = nil,
        outerGapRight: Double? = nil,
        outerGapTop: Double? = nil,
        outerGapBottom: Double? = nil,
        fullscreenUsesOuterGaps: Bool? = nil,
        activeWorkspace: IPCWorkspaceRef? = nil
    ) {
        self.id = id
        self.name = name
        self.isMain = isMain
        self.isCurrent = isCurrent
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.hasNotch = hasNotch
        self.orientation = orientation
        self.innerGap = innerGap
        self.outerGapLeft = outerGapLeft
        self.outerGapRight = outerGapRight
        self.outerGapTop = outerGapTop
        self.outerGapBottom = outerGapBottom
        self.fullscreenUsesOuterGaps = fullscreenUsesOuterGaps
        self.activeWorkspace = activeWorkspace
    }
}

public struct IPCDisplaysQueryResult: Codable, Equatable, Sendable {
    public let displays: [IPCDisplayQuerySnapshot]

    public init(displays: [IPCDisplayQuerySnapshot]) {
        self.displays = displays
    }
}
