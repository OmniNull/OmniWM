// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct TrackpadGestureConflict: Error, Equatable, LocalizedError {
    let fingerCount: Int
    let gesture: TrackpadGestureMode
    let otherGesture: TrackpadGestureMode

    var errorDescription: String? {
        let first = Self.name(for: gesture)
        let second = Self.name(for: otherGesture)
        if gesture == .overview(.open) {
            return String(
                localized: "\(first) and \(second) both use a \(fingerCount)-finger upward swipe. Choose different fingers or disable one gesture.",
                comment: "Trackpad gesture conflict; the placeholders are gesture names"
            )
        }
        return String(
            localized: "\(first) and \(second) both use a \(fingerCount)-finger gesture. Choose different fingers or disable one gesture.",
            comment: "Trackpad gesture conflict; the placeholders are gesture names"
        )
    }

    private static func name(for gesture: TrackpadGestureMode) -> String {
        switch gesture {
        case .columnScroll: String(localized: "Niri column scrolling", comment: "Trackpad gesture name")
        case .workspaceSwitch: String(localized: "workspace switching", comment: "Trackpad gesture name")
        case .overview: String(localized: "Overview", comment: "Trackpad gesture name")
        case .windowMove: String(localized: "window moving", comment: "Trackpad gesture name")
        case .windowResize: String(localized: "window resizing", comment: "Trackpad gesture name")
        }
    }
}

enum GestureSettingsValidation {
    static func validate(_ export: SettingsExport, monitorProvider: () -> [Monitor]) throws {
        guard export.gestures.overviewGestureEnabled == true || export.gestures.windowMoveEnabled == true
            || export.gestures.windowResizeEnabled == true else { return }
        if let conflict = conflict(
            gestures: export.gestures,
            orientationOverrides: export.monitorOrientationSettings,
            monitors: export.gestures.overviewGestureEnabled == true ? monitorProvider() : []
        ) {
            throw conflict
        }
    }

    static func conflict(
        gestures: SettingsExport.Gestures,
        orientationOverrides: [MonitorOrientationSettings],
        monitors: [Monitor]
    ) -> TrackpadGestureConflict? {
        let config = TrackpadGestureIntent.Config(
            columnScrollEnabled: gestures.scrollEnabled,
            columnScrollFingerCount: gestures.fingerCount.rawValue,
            workspaceSwipeEnabled: gestures.workspaceSwipeEnabled,
            workspaceSwipeFingerCount: gestures.workspaceSwipeFingerCount.rawValue,
            workspaceSwipeAxis: gestures.workspaceSwipeAxis,
            overviewAction: gestures.overviewGestureEnabled == true ? .open : nil,
            overviewFingerCount: (gestures.overviewGestureFingerCount ?? .four).rawValue,
            windowMoveEnabled: gestures.windowMoveEnabled ?? false,
            windowMoveFingerCount: (gestures.windowMoveFingerCount ?? .four).rawValue,
            windowResizeEnabled: gestures.windowResizeEnabled ?? false,
            windowResizeFingerCount: (gestures.windowResizeFingerCount ?? .three).rawValue
        )
        for (enabled, mode, fingers) in [
            (config.windowMoveEnabled, TrackpadGestureMode.windowMove, config.windowMoveFingerCount),
            (config.windowResizeEnabled, .windowResize, config.windowResizeFingerCount)
        ] where enabled {
            if let other = TrackpadGestureIntent.windowGestureConflict(config, mode: mode) {
                return TrackpadGestureConflict(fingerCount: fingers, gesture: mode, otherGesture: other)
            }
        }
        guard gestures.overviewGestureEnabled == true else { return nil }
        if let other = TrackpadGestureIntent.overviewConflict(config, columnScrollAxis: nil) {
            return TrackpadGestureConflict(
                fingerCount: config.overviewFingerCount,
                gesture: .overview(.open),
                otherGesture: other
            )
        }
        for monitor in monitors {
            let orientation = MonitorSettingsStore.get(for: monitor, in: orientationOverrides)?.orientation
                ?? monitor.autoOrientation
            if let other = TrackpadGestureIntent.overviewConflict(
                config,
                columnScrollAxis: orientation == .horizontal ? .horizontal : .vertical
            ) {
                return TrackpadGestureConflict(
                    fingerCount: config.overviewFingerCount,
                    gesture: .overview(.open),
                    otherGesture: other
                )
            }
        }
        return nil
    }
}
