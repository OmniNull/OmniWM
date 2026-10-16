// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct MonitorBarSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayUUID: String?
    var monitorDisplayId: CGDirectDisplayID?

    var enabled: Bool?
    var showLabels: Bool?
    var showFloatingWindows: Bool?
    var deduplicateAppIcons: Bool?
    var hideEmptyWorkspaces: Bool?
    var reserveLayoutSpace: Bool?
    var autoHide: Bool?
    var notchMode: WorkspaceBarNotchMode?
    var notchActiveZoneWidth: Double?
    var fullWidth: Bool?
    var fullWidthNotchMode: WorkspaceBarFullWidthNotchMode?
    var position: WorkspaceBarPosition?
    var windowLevel: WorkspaceBarWindowLevel?
    var height: Double?
    var backgroundOpacity: Double?
    var inactiveIconOpacity: Double?
    var transparentBackground: Bool?
    var solidBlackBackground: Bool?
    var showItemBackgrounds: Bool?
    var showAccentHighlights: Bool?
    var xOffset: Double?
    var yOffset: Double?

    init(
        id: UUID = UUID(),
        monitorName: String,
        monitorDisplayUUID: String? = nil,
        monitorDisplayId: CGDirectDisplayID? = nil,
        enabled: Bool? = nil,
        showLabels: Bool? = nil,
        showFloatingWindows: Bool? = nil,
        deduplicateAppIcons: Bool? = nil,
        hideEmptyWorkspaces: Bool? = nil,
        reserveLayoutSpace: Bool? = nil,
        autoHide: Bool? = nil,
        notchMode: WorkspaceBarNotchMode? = nil,
        notchActiveZoneWidth: Double? = nil,
        fullWidth: Bool? = nil,
        fullWidthNotchMode: WorkspaceBarFullWidthNotchMode? = nil,
        position: WorkspaceBarPosition? = nil,
        windowLevel: WorkspaceBarWindowLevel? = nil,
        height: Double? = nil,
        backgroundOpacity: Double? = nil,
        inactiveIconOpacity: Double? = nil,
        transparentBackground: Bool? = nil,
        solidBlackBackground: Bool? = nil,
        showItemBackgrounds: Bool? = nil,
        showAccentHighlights: Bool? = nil,
        xOffset: Double? = nil,
        yOffset: Double? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.monitorDisplayUUID = DisplayUUID.canonical(monitorDisplayUUID)
        self.monitorDisplayId = monitorDisplayId
        self.enabled = enabled
        self.showLabels = showLabels
        self.showFloatingWindows = showFloatingWindows
        self.deduplicateAppIcons = deduplicateAppIcons
        self.hideEmptyWorkspaces = hideEmptyWorkspaces
        self.reserveLayoutSpace = reserveLayoutSpace
        self.autoHide = autoHide
        self.notchMode = notchMode
        self.notchActiveZoneWidth = notchActiveZoneWidth
        self.fullWidth = fullWidth
        self.fullWidthNotchMode = fullWidthNotchMode
        self.position = position
        self.windowLevel = windowLevel
        self.height = height
        self.backgroundOpacity = backgroundOpacity
        self.inactiveIconOpacity = inactiveIconOpacity
        self.transparentBackground = transparentBackground
        self.solidBlackBackground = solidBlackBackground
        self.showItemBackgrounds = showItemBackgrounds
        self.showAccentHighlights = showAccentHighlights
        self.xOffset = xOffset
        self.yOffset = yOffset
    }

    private enum CodingKeys: String, CodingKey {
        case id, monitorName, monitorDisplayUUID, monitorDisplayId
        case enabled, showLabels, showFloatingWindows, deduplicateAppIcons
        case autoHide
        case hideEmptyWorkspaces, reserveLayoutSpace, notchMode, notchActiveZoneWidth, position, windowLevel
        case fullWidth, fullWidthNotchMode
        case height, backgroundOpacity, inactiveIconOpacity, transparentBackground, solidBlackBackground,
             showItemBackgrounds, showAccentHighlights, xOffset, yOffset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayUUID = try DisplayUUID.decode(from: container, forKey: .monitorDisplayUUID)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        showLabels = try container.decodeIfPresent(Bool.self, forKey: .showLabels)
        showFloatingWindows = try container.decodeIfPresent(Bool.self, forKey: .showFloatingWindows)
        deduplicateAppIcons = try container.decodeIfPresent(Bool.self, forKey: .deduplicateAppIcons)
        hideEmptyWorkspaces = try container.decodeIfPresent(Bool.self, forKey: .hideEmptyWorkspaces)
        reserveLayoutSpace = try container.decodeIfPresent(Bool.self, forKey: .reserveLayoutSpace)
        autoHide = try container.decodeIfPresent(Bool.self, forKey: .autoHide)
        notchMode = try container.decodeIfPresent(WorkspaceBarNotchMode.self, forKey: .notchMode)
        notchActiveZoneWidth = try container.decodeIfPresent(Double.self, forKey: .notchActiveZoneWidth)
        fullWidth = try container.decodeIfPresent(Bool.self, forKey: .fullWidth)
        fullWidthNotchMode = try container.decodeIfPresent(
            WorkspaceBarFullWidthNotchMode.self,
            forKey: .fullWidthNotchMode
        )
        position = try container.decodeIfPresent(WorkspaceBarPosition.self, forKey: .position)
        windowLevel = try container.decodeIfPresent(WorkspaceBarWindowLevel.self, forKey: .windowLevel)
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity)
        inactiveIconOpacity = try container.decodeIfPresent(Double.self, forKey: .inactiveIconOpacity)
        transparentBackground = try container.decodeIfPresent(Bool.self, forKey: .transparentBackground)
        solidBlackBackground = try container.decodeIfPresent(Bool.self, forKey: .solidBlackBackground)
        showItemBackgrounds = try container.decodeIfPresent(Bool.self, forKey: .showItemBackgrounds)
        showAccentHighlights = try container.decodeIfPresent(Bool.self, forKey: .showAccentHighlights)
        xOffset = try container.decodeIfPresent(Double.self, forKey: .xOffset)
        yOffset = try container.decodeIfPresent(Double.self, forKey: .yOffset)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(monitorName, forKey: .monitorName)
        try DisplayUUID.encode(
            monitorDisplayUUID,
            displayId: monitorDisplayId,
            to: &container,
            uuidKey: .monitorDisplayUUID,
            displayIdKey: .monitorDisplayId
        )
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(showLabels, forKey: .showLabels)
        try container.encodeIfPresent(showFloatingWindows, forKey: .showFloatingWindows)
        try container.encodeIfPresent(deduplicateAppIcons, forKey: .deduplicateAppIcons)
        try container.encodeIfPresent(hideEmptyWorkspaces, forKey: .hideEmptyWorkspaces)
        try container.encodeIfPresent(reserveLayoutSpace, forKey: .reserveLayoutSpace)
        try container.encodeIfPresent(autoHide, forKey: .autoHide)
        try container.encodeIfPresent(notchMode, forKey: .notchMode)
        try container.encodeIfPresent(notchActiveZoneWidth, forKey: .notchActiveZoneWidth)
        try container.encodeIfPresent(fullWidth, forKey: .fullWidth)
        try container.encodeIfPresent(fullWidthNotchMode, forKey: .fullWidthNotchMode)
        try container.encodeIfPresent(position, forKey: .position)
        try container.encodeIfPresent(windowLevel, forKey: .windowLevel)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(backgroundOpacity, forKey: .backgroundOpacity)
        try container.encodeIfPresent(inactiveIconOpacity, forKey: .inactiveIconOpacity)
        try container.encodeIfPresent(transparentBackground, forKey: .transparentBackground)
        try container.encodeIfPresent(solidBlackBackground, forKey: .solidBlackBackground)
        try container.encodeIfPresent(showItemBackgrounds, forKey: .showItemBackgrounds)
        try container.encodeIfPresent(showAccentHighlights, forKey: .showAccentHighlights)
        try container.encodeIfPresent(xOffset, forKey: .xOffset)
        try container.encodeIfPresent(yOffset, forKey: .yOffset)
    }
}

struct ResolvedBarSettings {
    let enabled: Bool
    let showLabels: Bool
    let showFloatingWindows: Bool
    let deduplicateAppIcons: Bool
    let hideEmptyWorkspaces: Bool
    let excludedBundleIDs: Set<String>
    let reserveLayoutSpace: Bool
    var autoHide = false
    let notchMode: WorkspaceBarNotchMode
    let notchActiveZoneWidth: Double
    var fullWidth = false
    var fullWidthNotchMode = WorkspaceBarFullWidthNotchMode.rightOfNotch
    let systemStatsButton: Bool
    let position: WorkspaceBarPosition
    let windowLevel: WorkspaceBarWindowLevel
    let height: Double
    let backgroundOpacity: Double
    let inactiveIconOpacity: Double?
    let transparentBackground: Bool
    let solidBlackBackground: Bool
    let showItemBackgrounds: Bool
    let showAccentHighlights: Bool
    let xOffset: Double
    let yOffset: Double
    let accentColor: SettingsColor?
    let textColor: SettingsColor?
    var barFill: ShellThemeColor?
    var barBorder: ShellThemeColor?
}

struct WorkspaceBarProfileOverride: Equatable {
    var profile: String
    var settings: MonitorBarSettings
    var monitorOverrides: [MonitorBarSettings] = []
    var accentColor: SettingsColor?
    var textColor: SettingsColor?
    var hoverPreviewsEnabled: Bool?
    var systemStatsButton: Bool?
    var hideInNativeFullscreen: Bool?
    var notificationBadges: WorkspaceBarNotificationBadgeMode?
    var notificationBadgeRefreshIntervalSeconds: Double?
    var autoHideRevealDelayMilliseconds: Double?
    var autoHideHideDelayMilliseconds: Double?
    var revealModifier: WorkspaceBarRevealModifier?
    var revealHoldMilliseconds: Double?
    var barFill: ShellThemeColor?
    var barBorder: ShellThemeColor?
    var usesThemeColors = false

    static let colorKeys: [(
        key: String,
        path: WritableKeyPath<WorkspaceBarProfileOverride, ShellThemeColor?> & Sendable
    )] = [
        ("barFill", \.barFill),
        ("barBorder", \.barBorder)
    ]

    static let flagKeys: [(key: String, path: WritableKeyPath<WorkspaceBarProfileOverride, Bool?> & Sendable)] = [
        ("hoverPreviewsEnabled", \.hoverPreviewsEnabled),
        ("systemStatsButton", \.systemStatsButton),
        ("hideInNativeFullscreen", \.hideInNativeFullscreen)
    ]

    static let numberKeys: [BarNumberKey<WorkspaceBarProfileOverride>] = [
        BarNumberKey("notificationBadgeRefreshIntervalSeconds", \.notificationBadgeRefreshIntervalSeconds, 1 ... 60),
        BarNumberKey("autoHideRevealDelayMilliseconds", \.autoHideRevealDelayMilliseconds, 0 ... 1000),
        BarNumberKey("autoHideHideDelayMilliseconds", \.autoHideHideDelayMilliseconds, 0 ... 1000),
        BarNumberKey("revealHoldMilliseconds", \.revealHoldMilliseconds, 0 ... 1000)
    ]

    var overriddenKeys: [String] {
        var keys = settings.overriddenKeys
            + Self.flagKeys.filter { self[keyPath: $0.path] != nil }.map(\.key)
            + Self.numberKeys.filter { self[keyPath: $0.path] != nil }.map(\.key)
            + Self.colorKeys.filter { self[keyPath: $0.path] != nil }.map(\.key)
        for (key, isSet) in [
            ("notificationBadges", notificationBadges != nil),
            ("revealModifier", revealModifier != nil),
            ("accentColor", usesThemeColors || accentColor != nil),
            ("textColor", usesThemeColors || textColor != nil),
            ("monitorBarOverrides", !monitorOverrides.isEmpty)
        ]
            where isSet
        {
            keys.append(key)
        }
        return keys.sorted()
    }
}

extension MonitorBarSettings {
    static let flagKeys: [(key: String, path: WritableKeyPath<MonitorBarSettings, Bool?> & Sendable)] = [
        ("enabled", \.enabled),
        ("showLabels", \.showLabels),
        ("showFloatingWindows", \.showFloatingWindows),
        ("deduplicateAppIcons", \.deduplicateAppIcons),
        ("hideEmptyWorkspaces", \.hideEmptyWorkspaces),
        ("reserveLayoutSpace", \.reserveLayoutSpace),
        ("autoHide", \.autoHide),
        ("fullWidth", \.fullWidth),
        ("transparentBackground", \.transparentBackground),
        ("solidBlackBackground", \.solidBlackBackground),
        ("showItemBackgrounds", \.showItemBackgrounds),
        ("showAccentHighlights", \.showAccentHighlights)
    ]

    static let numberKeys: [BarNumberKey<MonitorBarSettings>] = [
        BarNumberKey("notchActiveZoneWidth", \.notchActiveZoneWidth, 100 ... 400),
        BarNumberKey("height", \.height, 1 ... 200),
        BarNumberKey("backgroundOpacity", \.backgroundOpacity, 0 ... 1),
        BarNumberKey("inactiveIconOpacity", \.inactiveIconOpacity, 0 ... 1),
        BarNumberKey("xOffset", \.xOffset, -10000 ... 10000),
        BarNumberKey("yOffset", \.yOffset, -10000 ... 10000)
    ]

    var overriddenKeys: [String] {
        var keys = Self.flagKeys.filter { self[keyPath: $0.path] != nil }.map(\.key)
            + Self.numberKeys.filter { self[keyPath: $0.path] != nil }.map(\.key)
        for (key, isSet) in [
            ("notchMode", notchMode != nil),
            ("fullWidthNotchMode", fullWidthNotchMode != nil),
            ("position", position != nil),
            ("windowLevel", windowLevel != nil)
        ]
            where isSet
        {
            keys.append(key)
        }
        return keys.sorted()
    }

    func overlaid(by top: MonitorBarSettings) -> MonitorBarSettings {
        var result = self
        for (_, path) in Self.flagKeys where top[keyPath: path] != nil {
            result[keyPath: path] = top[keyPath: path]
        }
        for entry in Self.numberKeys where top[keyPath: entry.path] != nil {
            result[keyPath: entry.path] = top[keyPath: entry.path]
        }
        result.notchMode = top.notchMode ?? notchMode
        result.fullWidthNotchMode = top.fullWidthNotchMode ?? fullWidthNotchMode
        result.position = top.position ?? position
        result.windowLevel = top.windowLevel ?? windowLevel
        return result
    }
}

struct BarNumberKey<Root>: Sendable {
    let key: String
    let path: WritableKeyPath<Root, Double?> & Sendable
    let range: ClosedRange<Double>

    init(_ key: String, _ path: WritableKeyPath<Root, Double?> & Sendable, _ range: ClosedRange<Double>) {
        self.key = key
        self.path = path
        self.range = range
    }
}
