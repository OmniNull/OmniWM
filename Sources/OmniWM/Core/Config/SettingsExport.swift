// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

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
    var windowSwitcher = WindowSwitcher()
    var keyboardModes = KeyboardModes()
    var workspaceAutoBackAndForth = false

    var hotkeyBindings: [HotkeyBinding]
    var systemHyperTrigger: SystemHyperTrigger
    var hyperKeyModifiers: HyperKeyModifiers

    var workspaceBar: WorkspaceBar
    var island: Island
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
    var animationSpeed: Double
    var language: String?

    var launcher = LauncherConfiguration()

    var clipboard: Clipboard

    var quakeTerminal: QuakeTerminal

    var appearanceMode: AppearanceMode
    var tabRailAppIcons: Bool
    var shellPermissions = ShellPermissionDecisions()

    struct Island: Codable, Equatable {
        var enabled: Bool
    }

    struct Focus: Codable, Equatable {
        var followsMouse: Bool
        var followsMouseOnlyFullyVisible: Bool = false
        var edgeNavigationInterval: Double
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
        var edgeGaps: Bool?
        var resizeStepPercent: Int?
        var moveWindowStacksIntoColumn: Bool?
        var allowOverscroll: Bool?
        var overscrollVisibleStripPercent: Int?
    }

    struct Dwindle: Codable, Equatable {
        var smartSplit: Bool
        var defaultSplitRatio: Double
        var splitWidthMultiplier: Double
        var singleWindowFit: SingleWindowFit
        var useGlobalGaps: Bool
        var moveToRootStable: Bool
    }

    struct Overview: Codable, Equatable {
        var enabled: Bool?
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
        var provider: QuakeTerminalProvider?
        var kitty: KittyQuakeSettings?
        var foot: FootQuakeSettings?
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
        var fingerCount: ThreeOrFourFingerCount
        var invertDirection: Bool
        var trackpadScrollStyle: TrackpadScrollStyle
        var workspaceSwipeEnabled: Bool
        var workspaceSwipeFingerCount: GestureFingerCount
        var workspaceSwipeAxis: WorkspaceSwipeAxis
        var workspaceSwipeEdgeBehavior: WorkspaceSwipeEdgeBehavior? = .cycle
        var overviewGestureEnabled: Bool? = false
        var overviewGestureFingerCount: ThreeOrFourFingerCount? = .four
        var windowMoveEnabled: Bool? = false
        var windowMoveFingerCount: GestureFingerCount? = .four
        var windowResizeEnabled: Bool? = false
        var windowResizeFingerCount: GestureFingerCount? = .three
        var windowGestureSensitivity: Double? = 1.0
        var resizePreviewStyle: ResizePreviewStyle? = .live
        var dwindleGroupDragAcrossDisplays: DwindleGroupDrag? = .group
        var adoptNativeResize: Bool? = false
        var adoptNativeMoveAcrossDisplays: Bool? = false
    }

    struct StatusBar: Codable, Equatable {
        var showWorkspaceName: Bool
        var showAppNames: Bool
        var useWorkspaceId: Bool
        var showIcon: Bool? = true
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

extension SettingsExport.Focus {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        followsMouse = try container.decode(Bool.self, forKey: .followsMouse)
        followsMouseOnlyFullyVisible = try container.decodeIfPresent(Bool.self, forKey: .followsMouseOnlyFullyVisible)
            ?? Self.defaults().followsMouseOnlyFullyVisible
        edgeNavigationInterval = try container.decodeIfPresent(Double.self, forKey: .edgeNavigationInterval)
            ?? Self.defaults().edgeNavigationInterval
        raiseOnMouseFocus = try container.decode(Bool.self, forKey: .raiseOnMouseFocus)
        lockModifier = try container.decode(FocusLockModifier.self, forKey: .lockModifier)
        moveMouseToFocusedWindow = try container.decode(Bool.self, forKey: .moveMouseToFocusedWindow)
        followsWindowToMonitor = try container.decode(Bool.self, forKey: .followsWindowToMonitor)
        crossesMonitorAtEdge = try container.decode(Bool.self, forKey: .crossesMonitorAtEdge)
        moveCrossesMonitorAtEdge = try container.decode(Bool.self, forKey: .moveCrossesMonitorAtEdge)
    }
}
