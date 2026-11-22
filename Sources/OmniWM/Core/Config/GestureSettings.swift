// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation
import OmniWMIPC

@MainActor @Observable
final class GestureSettings {
    private nonisolated static let defaults = SettingsExport.Gestures.defaults()
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onWorkspaceSwipeEnabledChange: (() -> Void)?

    @ObservationIgnored private var isApplying = false

    nonisolated static let windowGestureSensitivityRange = 0.1 ... 5.0
    nonisolated static let mouseWheelSensitivityRange = 0.1 ... 10.0

    private nonisolated static let scrollSensitivityRange = 0.1 ... 100.0

    private nonisolated static func normalizedWindowSensitivity(_ value: Double, defaultValue: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, windowGestureSensitivityRange.lowerBound), windowGestureSensitivityRange.upperBound)
    }

    private nonisolated static func normalizedScrollSensitivity(_ value: Double) -> Double {
        guard value.isFinite else { return defaults.scrollSensitivity }
        return min(max(value, scrollSensitivityRange.lowerBound), scrollSensitivityRange.upperBound)
    }

    nonisolated static func normalizedMouseWheelSensitivity(_ value: Double) -> Double {
        guard value.isFinite else { return defaults.mouseWheelSensitivity ?? 1.0 }
        return min(max(value, mouseWheelSensitivityRange.lowerBound), mouseWheelSensitivityRange.upperBound)
    }

    var scrollEnabled = GestureSettings.defaults.scrollEnabled {
        didSet {
            guard oldValue != scrollEnabled else { return }
            notifyChange()
        }
    }

    var scrollSensitivity = GestureSettings.defaults.scrollSensitivity {
        didSet {
            let normalized = GestureSettings.normalizedScrollSensitivity(scrollSensitivity)
            guard normalized == scrollSensitivity else {
                scrollSensitivity = normalized
                return
            }
            notifyChange()
        }
    }

    var scrollModifierKey = GestureSettings.defaults.scrollModifierKey {
        didSet { notifyChange() }
    }

    var mouseWheelSensitivity = GestureSettings.defaults.mouseWheelSensitivity ?? 1.0 {
        didSet {
            let normalized = GestureSettings.normalizedMouseWheelSensitivity(mouseWheelSensitivity)
            guard normalized == mouseWheelSensitivity else {
                mouseWheelSensitivity = normalized
                return
            }
            notifyChange()
        }
    }

    var fingerCount = GestureSettings.defaults.fingerCount {
        didSet { notifyChange() }
    }

    var invertDirection = GestureSettings.defaults.invertDirection {
        didSet { notifyChange() }
    }

    var trackpadScrollStyle = GestureSettings.defaults.trackpadScrollStyle {
        didSet { notifyChange() }
    }

    var workspaceSwipeEnabled = GestureSettings.defaults.workspaceSwipeEnabled {
        didSet {
            guard oldValue != workspaceSwipeEnabled else { return }
            onWorkspaceSwipeEnabledChange?()
            notifyChange()
        }
    }

    var workspaceSwipeFingerCount = GestureSettings.defaults.workspaceSwipeFingerCount {
        didSet { notifyChange() }
    }

    var workspaceSwipeAxis = GestureSettings.defaults.workspaceSwipeAxis {
        didSet { notifyChange() }
    }

    var workspaceSwipeEdgeBehavior = GestureSettings.defaults.workspaceSwipeEdgeBehavior ?? .cycle {
        didSet { notifyChange() }
    }

    var overviewGestureEnabled = GestureSettings.defaults.overviewGestureEnabled ?? false {
        didSet {
            guard oldValue != overviewGestureEnabled else { return }
            notifyChange()
        }
    }

    var overviewGestureFingerCount = GestureSettings.defaults.overviewGestureFingerCount ?? .four {
        didSet { notifyChange() }
    }

    var windowMoveEnabled = GestureSettings.defaults.windowMoveEnabled ?? false {
        didSet {
            guard oldValue != windowMoveEnabled else { return }
            notifyChange()
        }
    }

    var windowMoveFingerCount = GestureSettings.defaults.windowMoveFingerCount ?? .four {
        didSet { notifyChange() }
    }

    var windowResizeEnabled = GestureSettings.defaults.windowResizeEnabled ?? false {
        didSet {
            guard oldValue != windowResizeEnabled else { return }
            notifyChange()
        }
    }

    var windowResizeFingerCount = GestureSettings.defaults.windowResizeFingerCount ?? .three {
        didSet { notifyChange() }
    }

    var windowMoveSensitivity = SettingsExport.Gestures.defaultMoveSensitivity {
        didSet {
            let normalized = GestureSettings.normalizedWindowSensitivity(
                windowMoveSensitivity, defaultValue: SettingsExport.Gestures.defaultMoveSensitivity
            )
            guard normalized == windowMoveSensitivity else {
                windowMoveSensitivity = normalized
                return
            }
            notifyChange()
        }
    }

    var windowResizeSensitivity = SettingsExport.Gestures.defaultResizeSensitivity {
        didSet {
            let normalized = GestureSettings.normalizedWindowSensitivity(
                windowResizeSensitivity, defaultValue: SettingsExport.Gestures.defaultResizeSensitivity
            )
            guard normalized == windowResizeSensitivity else {
                windowResizeSensitivity = normalized
                return
            }
            notifyChange()
        }
    }

    var dwindleGroupDragAcrossDisplays = GestureSettings.defaults.dwindleGroupDragAcrossDisplays ?? .group {
        didSet { notifyChange() }
    }

    var workspaceSwipeAxisLockedToVertical: Bool {
        scrollEnabled && workspaceSwipeFingerCount.rawValue == fingerCount.rawValue
    }

    var effectiveWorkspaceSwipeAxis: WorkspaceSwipeAxis {
        workspaceSwipeAxisLockedToVertical ? .vertical : workspaceSwipeAxis
    }

    func export() -> SettingsExport.Gestures {
        SettingsExport.Gestures(
            scrollEnabled: scrollEnabled,
            scrollSensitivity: scrollSensitivity,
            scrollModifierKey: scrollModifierKey,
            fingerCount: fingerCount,
            invertDirection: invertDirection,
            trackpadScrollStyle: trackpadScrollStyle,
            workspaceSwipeEnabled: workspaceSwipeEnabled,
            workspaceSwipeFingerCount: workspaceSwipeFingerCount,
            workspaceSwipeAxis: workspaceSwipeAxis,
            workspaceSwipeEdgeBehavior: workspaceSwipeEdgeBehavior,
            overviewGestureEnabled: overviewGestureEnabled,
            overviewGestureFingerCount: overviewGestureFingerCount,
            windowMoveEnabled: windowMoveEnabled,
            windowMoveFingerCount: windowMoveFingerCount,
            windowResizeEnabled: windowResizeEnabled,
            windowResizeFingerCount: windowResizeFingerCount,
            windowMoveSensitivity: windowMoveSensitivity,
            windowGestureSensitivity: windowResizeSensitivity,
            dwindleGroupDragAcrossDisplays: dwindleGroupDragAcrossDisplays,
            mouseWheelSensitivity: mouseWheelSensitivity
        )
    }

    private func notifyChange() {
        guard !isApplying else { return }
        onChange?()
    }

    func apply(_ gestures: SettingsExport.Gestures) {
        let previous = export()
        isApplying = true
        scrollEnabled = gestures.scrollEnabled
        scrollSensitivity = gestures.scrollSensitivity
        mouseWheelSensitivity = gestures.mouseWheelSensitivity ?? 1.0
        scrollModifierKey = gestures.scrollModifierKey
        fingerCount = gestures.fingerCount
        invertDirection = gestures.invertDirection
        trackpadScrollStyle = gestures.trackpadScrollStyle
        workspaceSwipeEnabled = gestures.workspaceSwipeEnabled
        workspaceSwipeFingerCount = gestures.workspaceSwipeFingerCount
        workspaceSwipeAxis = gestures.workspaceSwipeAxis
        workspaceSwipeEdgeBehavior = gestures.workspaceSwipeEdgeBehavior ?? .cycle
        overviewGestureEnabled = gestures.overviewGestureEnabled ?? false
        overviewGestureFingerCount = gestures.overviewGestureFingerCount ?? .four
        windowMoveEnabled = gestures.windowMoveEnabled ?? false
        windowMoveFingerCount = gestures.windowMoveFingerCount ?? .four
        windowResizeEnabled = gestures.windowResizeEnabled ?? false
        windowResizeFingerCount = gestures.windowResizeFingerCount ?? .three
        windowMoveSensitivity = gestures.windowMoveSensitivity ?? SettingsExport.Gestures.defaultMoveSensitivity
        windowResizeSensitivity = gestures.windowGestureSensitivity ?? SettingsExport.Gestures.defaultResizeSensitivity
        dwindleGroupDragAcrossDisplays = gestures.dwindleGroupDragAcrossDisplays ?? .group
        isApplying = false
        if export() != previous {
            notifyChange()
        }
    }
}
