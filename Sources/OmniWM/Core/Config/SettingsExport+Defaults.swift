// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension SettingsExport.Island {
    static func defaults() -> Self {
        Self(enabled: false)
    }
}

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
            island: Island.defaults(),
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
            animationSpeed: 1,
            language: nil,
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
            edgeNavigationInterval: 1.5,
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
            defaultContainerPrimarySpan: 0.5,
            edgeGaps: true,
            resizeStepPercent: BuiltInSettingsDefaults.niriResizeStepPercent,
            moveWindowStacksIntoColumn: true,
            allowOverscroll: false,
            overscrollVisibleStripPercent: 5
        )
    }
}

extension SettingsExport.Dwindle {
    static func defaults() -> Self {
        Self(
            smartSplit: false,
            defaultSplitRatio: 1.0,
            splitWidthMultiplier: 1.0,
            singleWindowFit: .fullScreen,
            useGlobalGaps: true,
            moveToRootStable: true
        )
    }
}

extension SettingsExport.Overview {
    static func defaults() -> Self {
        Self(
            enabled: true,
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
            monitorMode: .focusedWindow,
            provider: .ghostty,
            kitty: nil,
            foot: nil
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
            workspaceSwipeAxis: .vertical,
            resizePreviewStyle: .live,
            dwindleGroupDragAcrossDisplays: .group,
            adoptNativeResize: false,
            adoptNativeMoveAcrossDisplays: false
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
