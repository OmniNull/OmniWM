// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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

    private nonisolated static let scrollSensitivityRange = 0.1 ... 100.0

    private nonisolated static func normalizedScrollSensitivity(_ value: Double) -> Double {
        guard value.isFinite else { return defaults.scrollSensitivity }
        return min(max(value, scrollSensitivityRange.lowerBound), scrollSensitivityRange.upperBound)
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

    var mouseMoveModifierKey = GestureSettings.defaults.mouseMoveModifierKey {
        didSet { notifyChange() }
    }

    var mouseResizeModifierKey = GestureSettings.defaults.mouseResizeModifierKey {
        didSet { notifyChange() }
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

    var windowGestureSensitivity = GestureSettings.defaults.windowGestureSensitivity ?? 1.0 {
        didSet {
            let range = GestureSettings.windowGestureSensitivityRange
            let normalized = windowGestureSensitivity.isFinite
                ? min(max(windowGestureSensitivity, range.lowerBound), range.upperBound)
                : GestureSettings.defaults.windowGestureSensitivity ?? 1.0
            guard normalized == windowGestureSensitivity else {
                windowGestureSensitivity = normalized
                return
            }
            notifyChange()
        }
    }

    var workspaceSwipeAxisLockedToVertical: Bool {
        scrollEnabled && workspaceSwipeFingerCount == fingerCount
    }

    var effectiveWorkspaceSwipeAxis: WorkspaceSwipeAxis {
        workspaceSwipeAxisLockedToVertical ? .vertical : workspaceSwipeAxis
    }

    func export() -> SettingsExport.Gestures {
        SettingsExport.Gestures(
            scrollEnabled: scrollEnabled,
            scrollSensitivity: scrollSensitivity,
            scrollModifierKey: scrollModifierKey,
            mouseMoveModifierKey: mouseMoveModifierKey,
            mouseResizeModifierKey: mouseResizeModifierKey,
            fingerCount: fingerCount,
            invertDirection: invertDirection,
            trackpadScrollStyle: trackpadScrollStyle,
            workspaceSwipeEnabled: workspaceSwipeEnabled,
            workspaceSwipeFingerCount: workspaceSwipeFingerCount,
            workspaceSwipeAxis: workspaceSwipeAxis,
            overviewGestureEnabled: overviewGestureEnabled,
            overviewGestureFingerCount: overviewGestureFingerCount,
            windowMoveEnabled: windowMoveEnabled,
            windowMoveFingerCount: windowMoveFingerCount,
            windowResizeEnabled: windowResizeEnabled,
            windowResizeFingerCount: windowResizeFingerCount,
            windowGestureSensitivity: windowGestureSensitivity
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
        scrollModifierKey = gestures.scrollModifierKey
        mouseMoveModifierKey = gestures.mouseMoveModifierKey
        mouseResizeModifierKey = gestures.mouseResizeModifierKey
        fingerCount = gestures.fingerCount
        invertDirection = gestures.invertDirection
        trackpadScrollStyle = gestures.trackpadScrollStyle
        workspaceSwipeEnabled = gestures.workspaceSwipeEnabled
        workspaceSwipeFingerCount = gestures.workspaceSwipeFingerCount
        workspaceSwipeAxis = gestures.workspaceSwipeAxis
        overviewGestureEnabled = gestures.overviewGestureEnabled ?? false
        overviewGestureFingerCount = gestures.overviewGestureFingerCount ?? .four
        windowMoveEnabled = gestures.windowMoveEnabled ?? false
        windowMoveFingerCount = gestures.windowMoveFingerCount ?? .four
        windowResizeEnabled = gestures.windowResizeEnabled ?? false
        windowResizeFingerCount = gestures.windowResizeFingerCount ?? .three
        windowGestureSensitivity = gestures.windowGestureSensitivity ?? 1.0
        isApplying = false
        if export() != previous {
            notifyChange()
        }
    }
}
