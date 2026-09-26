// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

// MARK: - SettingsExport

struct SettingsColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
}

enum BorderGradientDirection: String, Codable, CaseIterable, Equatable, Hashable {
    case topLeftToBottomRight
    case topRightToBottomLeft
}

struct BorderGradientColors: Codable, Equatable {
    var start: SettingsColor?
    var end: SettingsColor?
}

struct BorderGradient: Codable, Equatable {
    var enabled: Bool
    var start: SettingsColor
    var end: SettingsColor
    var direction: BorderGradientDirection
    var dark: BorderGradientColors?

    static let `default` = BorderGradient(
        enabled: false,
        start: SettingsColor(red: 0.0, green: 0.4, blue: 1.0, alpha: 1.0),
        end: SettingsColor(red: 0.0, green: 1.0, blue: 0.7, alpha: 1.0),
        direction: .topLeftToBottomRight
    )
}

struct BorderGlow: Codable, Equatable {
    var enabled: Bool
    var radius: Double
    var opacity: Double
    var color: SettingsColor?
    var darkColor: SettingsColor?

    static let `default` = BorderGlow(enabled: false, radius: 8.0, opacity: 0.6)
}

struct SettingsExport: Equatable {
    var hotkeysEnabled: Bool
    var focus: Focus
    var mouseWarp: MouseWarp
    var routing: Routing
    var monitorRanking: [OutputId]
    var gaps: Gaps

    var niri: Niri

    var workspaceConfigurations: [WorkspaceConfiguration]
    var defaultLayoutType: LayoutType

    var borders: Borders

    var overview: Overview

    var hotkeyBindings: [HotkeyBinding]
    var systemHyperTrigger: SystemHyperTrigger
    var hyperKeyModifiers: HyperKeyModifiers

    var workspaceBar: WorkspaceBar
    var scratchpads: Scratchpads
    var monitorBarSettings: [MonitorBarSettings]

    var appRules: [AppRule]
    var monitorOrientationSettings: [MonitorOrientationSettings]
    var monitorNiriSettings: [MonitorNiriSettings]

    var dwindle: Dwindle
    var monitorDwindleSettings: [MonitorDwindleSettings]

    var monitorGapSettings: [MonitorGapSettings]

    var preventSleepEnabled: Bool
    var updateChecksEnabled: Bool
    var ipcEnabled: Bool
    var gestures: Gestures
    var statusBar: StatusBar
    var hiddenBar: HiddenBar
    var animationsEnabled: Bool

    var clipboard: Clipboard

    var quakeTerminal: QuakeTerminal

    var appearanceMode: AppearanceMode
    var tabRailAppIcons: Bool

    struct Focus: Codable, Equatable {
        var followsMouse: Bool
        var raiseOnMouseFocus: Bool
        var lockModifier: FocusLockModifier
        var moveMouseToFocusedWindow: Bool
        var followsWindowToMonitor: Bool
        var crossesMonitorAtEdge: Bool
        var moveCrossesMonitorAtEdge: Bool
    }

    struct MouseWarp: Codable, Equatable {
        var margin: Int
        var enabled: Bool
        var constrainToArrangement: Bool
    }

    struct Routing: Codable, Equatable {
        var mode: MonitorRoutingMode
        var arrangements: [MonitorArrangement]
    }

    struct Gaps: Codable, Equatable {
        var size: Double
        var fullscreenUsesOuterGaps: Bool
        var outer: OuterGaps
    }

    struct OuterGaps: Codable, Equatable {
        var left: Double
        var right: Double
        var top: Double
        var bottom: Double
    }

    struct Niri: Codable, Equatable {
        var visibleContainerCount: Int
        var infiniteLoop: Bool
        var centerFocusedColumn: CenterFocusedColumn
        var alwaysCenterSingleColumn: Bool
        var singleWindowFit: SingleWindowFit
        var containerPrimarySpanPresets: [Double]?
        var defaultContainerPrimarySpan: Double?
    }

    struct Dwindle: Codable, Equatable {
        var smartSplit: Bool
        var defaultSplitRatio: Double
        var splitWidthMultiplier: Double
        var singleWindowFit: SingleWindowFit
        var useGlobalGaps: Bool
        var moveToRootStable: Bool
        var stackIncomingWindows: Bool
    }

    struct Overview: Codable, Equatable {
        var zoom: Double
        var backdrop: SettingsColor
        var windowBorders: OverviewWindowBorders
        var matchFocusBorder: Bool?
        var invertScrollDirection: Bool?
        var mouseScrollSpeed: Double?
        var mouseButton: Int64?
    }

    struct OverviewWindowBorders: Codable, Equatable {
        var normal: SettingsColor
        var hovered: SettingsColor
        var selected: SettingsColor
    }

    struct QuakeTerminal: Codable, Equatable {
        var enabled: Bool
        var position: QuakeTerminalPosition
        var widthPercent: Double
        var heightPercent: Double
        var animationDuration: Double
        var autoHide: Bool
        var opacity: Double?
        var backgroundEffect: QuakeTerminalBackgroundEffect
        var backgroundBlurRadius: Int?
        var monitorMode: QuakeTerminalMonitorMode?
    }

    struct Borders: Codable, Equatable {
        var enabled: Bool
        var width: Double
        var color: SettingsColor
        var darkColor: SettingsColor?
        var gradient: BorderGradient?
        var glow: BorderGlow?
    }

    struct Gestures: Codable, Equatable {
        var scrollEnabled: Bool
        var scrollSensitivity: Double
        var scrollModifierKey: ScrollModifierKey
        var mouseMoveModifierKey: MouseMoveModifierKey
        var mouseResizeModifierKey: MouseResizeModifierKey
        var fingerCount: GestureFingerCount
        var invertDirection: Bool
        var trackpadScrollStyle: TrackpadScrollStyle
        var workspaceSwipeEnabled: Bool
        var workspaceSwipeFingerCount: GestureFingerCount
        var workspaceSwipeAxis: WorkspaceSwipeAxis
        var overviewGestureEnabled: Bool? = false
        var overviewGestureFingerCount: OverviewGestureFingerCount? = .four
        var windowMoveEnabled: Bool? = false
        var windowMoveFingerCount: GestureFingerCount? = .four
        var windowResizeEnabled: Bool? = false
        var windowResizeFingerCount: GestureFingerCount? = .three
        var windowGestureSensitivity: Double? = 1.0
    }

    struct StatusBar: Codable, Equatable {
        var showWorkspaceName: Bool
        var showAppNames: Bool
        var useWorkspaceId: Bool
    }

    struct HiddenBar: Codable, Equatable {
        var enabled: Bool
        var hiddenBundleIDs: [String]
        var rehideIntervalSeconds: Double
    }

    struct Scratchpads: Codable, Equatable {
        var labels: [String: String]
    }

    struct Clipboard: Codable, Equatable {
        var historyEnabled: Bool
        var maxItems: Int
        var maxItemBytes: Int
        var maxTotalBytes: Int
        var ignoredTypes: [String]

        init(
            historyEnabled: Bool,
            maxItems: Int,
            maxItemBytes: Int,
            maxTotalBytes: Int,
            ignoredTypes: [String] = []
        ) {
            self.historyEnabled = historyEnabled
            self.maxItems = maxItems
            self.maxItemBytes = maxItemBytes
            self.maxTotalBytes = maxTotalBytes
            self.ignoredTypes = ignoredTypes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: ClipboardCodingKey.self)
            historyEnabled = try container.decode(Bool.self, forKey: .historyEnabled)
            maxItems = try container.decode(Int.self, forKey: .maxItems)
            maxItemBytes = try container.decode(Int.self, forKey: .maxItemBytes)
            maxTotalBytes = try container.decode(Int.self, forKey: .maxTotalBytes)
            ignoredTypes = try container.decodeIfPresent([String].self, forKey: .ignoredTypes) ?? []
        }
    }
}

private enum ClipboardCodingKey: String, CodingKey {
    case historyEnabled
    case maxItems
    case maxItemBytes
    case maxTotalBytes
    case ignoredTypes
}

// MARK: - Defaults & Diffing

extension SettingsExport {
    static func defaults() -> SettingsExport {
        SettingsExport(
            hotkeysEnabled: true,
            focus: Focus.defaults(),
            mouseWarp: MouseWarp.defaults(),
            routing: Routing.defaults(),
            monitorRanking: [],
            gaps: Gaps.defaults(),
            niri: Niri.defaults(),
            workspaceConfigurations: BuiltInSettingsDefaults.workspaceConfigurations,
            defaultLayoutType: .niri,
            borders: Borders.defaults(),
            overview: Overview.defaults(),
            hotkeyBindings: HotkeyBindingRegistry.defaults(),
            systemHyperTrigger: .default,
            hyperKeyModifiers: .default,
            workspaceBar: WorkspaceBar.defaults(),
            scratchpads: Scratchpads(labels: [:]),
            monitorBarSettings: [],
            appRules: BuiltInSettingsDefaults.appRules,
            monitorOrientationSettings: [],
            monitorNiriSettings: [],
            dwindle: Dwindle.defaults(),
            monitorDwindleSettings: [],
            monitorGapSettings: [],
            preventSleepEnabled: false,
            updateChecksEnabled: true,
            ipcEnabled: false,
            gestures: Gestures.defaults(),
            statusBar: StatusBar.defaults(),
            hiddenBar: HiddenBar.defaults(),
            animationsEnabled: true,
            clipboard: Clipboard.defaults(),
            quakeTerminal: QuakeTerminal.defaults(),
            appearanceMode: .dark,
            tabRailAppIcons: false
        )
    }
}

extension SettingsExport.Clipboard {
    static func defaults() -> Self {
        Self(
            historyEnabled: false,
            maxItems: 200,
            maxItemBytes: 8_388_608,
            maxTotalBytes: 67_108_864,
            ignoredTypes: []
        )
    }
}

extension SettingsExport.Focus {
    static func defaults() -> Self {
        Self(
            followsMouse: false,
            raiseOnMouseFocus: false,
            lockModifier: .off,
            moveMouseToFocusedWindow: false,
            followsWindowToMonitor: false,
            crossesMonitorAtEdge: false,
            moveCrossesMonitorAtEdge: false
        )
    }
}

extension SettingsExport.MouseWarp {
    static func defaults() -> Self {
        Self(
            margin: 1,
            enabled: true,
            constrainToArrangement: false
        )
    }
}

extension SettingsExport.Routing {
    static func defaults() -> Self {
        Self(
            mode: .macOS,
            arrangements: []
        )
    }
}

extension SettingsExport.Gaps {
    static func defaults() -> Self {
        Self(
            size: 16,
            fullscreenUsesOuterGaps: false,
            outer: SettingsExport.OuterGaps(left: 0, right: 0, top: 0, bottom: 0)
        )
    }
}

extension SettingsExport.Niri {
    static func defaults() -> Self {
        Self(
            visibleContainerCount: 2,
            infiniteLoop: false,
            centerFocusedColumn: .never,
            alwaysCenterSingleColumn: false,
            singleWindowFit: .fullScreen,
            containerPrimarySpanPresets: BuiltInSettingsDefaults.niriContainerPrimarySpanPresets,
            defaultContainerPrimarySpan: 0.5
        )
    }
}

extension SettingsExport.Dwindle {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        smartSplit = try container.decode(Bool.self, forKey: .smartSplit)
        defaultSplitRatio = try container.decode(Double.self, forKey: .defaultSplitRatio)
        splitWidthMultiplier = try container.decode(Double.self, forKey: .splitWidthMultiplier)
        singleWindowFit = try container.decode(SingleWindowFit.self, forKey: .singleWindowFit)
        useGlobalGaps = try container.decode(Bool.self, forKey: .useGlobalGaps)
        moveToRootStable = try container.decode(Bool.self, forKey: .moveToRootStable)
        stackIncomingWindows = try container.decodeIfPresent(Bool.self, forKey: .stackIncomingWindows) ?? false
    }

    static func defaults() -> Self {
        Self(
            smartSplit: false,
            defaultSplitRatio: 1.0,
            splitWidthMultiplier: 1.0,
            singleWindowFit: .fullScreen,
            useGlobalGaps: true,
            moveToRootStable: true,
            stackIncomingWindows: false
        )
    }
}

extension SettingsExport.Overview {
    static func defaults() -> Self {
        Self(
            zoom: 1.0,
            backdrop: SettingsColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 0),
            windowBorders: SettingsExport.OverviewWindowBorders(
                normal: SettingsColor(red: 0.3, green: 0.3, blue: 0.35, alpha: 0.5),
                hovered: SettingsColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0),
                selected: SettingsColor(red: 0.3, green: 0.8, blue: 0.4, alpha: 1.0)
            ),
            matchFocusBorder: true,
            invertScrollDirection: false,
            mouseScrollSpeed: 1.0
        )
    }
}

extension SettingsExport.QuakeTerminal {
    static func defaults() -> Self {
        Self(
            enabled: true,
            position: .center,
            widthPercent: 50.0,
            heightPercent: 50.0,
            animationDuration: 0.2,
            autoHide: false,
            opacity: 1.0,
            backgroundEffect: .standardBlur,
            backgroundBlurRadius: QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius,
            monitorMode: .focusedWindow
        )
    }
}

extension SettingsExport.Borders {
    static func defaults() -> Self {
        Self(
            enabled: true,
            width: 5.0,
            color: SettingsColor(
                red: 0.084585202284378935,
                green: 1.0,
                blue: 0.97930003794467602,
                alpha: 1.0
            ),
            darkColor: nil,
            gradient: nil,
            glow: nil
        )
    }
}

extension SettingsExport.Gestures {
    static func defaults() -> Self {
        Self(
            scrollEnabled: true,
            scrollSensitivity: 5.0,
            scrollModifierKey: .optionShift,
            mouseMoveModifierKey: .option,
            mouseResizeModifierKey: .option,
            fingerCount: .three,
            invertDirection: true,
            trackpadScrollStyle: .snap,
            workspaceSwipeEnabled: false,
            workspaceSwipeFingerCount: .three,
            workspaceSwipeAxis: .vertical
        )
    }
}

extension SettingsExport.StatusBar {
    static func defaults() -> Self {
        Self(
            showWorkspaceName: false,
            showAppNames: false,
            useWorkspaceId: false
        )
    }
}

extension SettingsExport.HiddenBar {
    static func defaults() -> Self {
        Self(
            enabled: true,
            hiddenBundleIDs: [],
            rehideIntervalSeconds: 5
        )
    }
}
