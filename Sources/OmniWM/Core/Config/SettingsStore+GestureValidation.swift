// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension SettingsStore {
    var effectiveTrackpadGesturesEnabled: Bool {
        gestures.scrollEnabled || gestures.workspaceSwipeEnabled ||
            (gestures.overviewGestureEnabled && overview.enabled) ||
            gestures.windowMoveEnabled || gestures.windowResizeEnabled
    }

    func updateGestureSettings(
        _ candidate: SettingsExport.Gestures,
        monitors: [Monitor]
    ) -> TrackpadGestureConflict? {
        var disabledCandidate = gestures.export()
        disabledCandidate.scrollEnabled = disabledCandidate.scrollEnabled && candidate.scrollEnabled
        disabledCandidate.workspaceSwipeEnabled = disabledCandidate.workspaceSwipeEnabled && candidate
            .workspaceSwipeEnabled
        disabledCandidate.overviewGestureEnabled =
            (disabledCandidate.overviewGestureEnabled ?? false) && (candidate.overviewGestureEnabled ?? false)
        disabledCandidate.windowMoveEnabled =
            (disabledCandidate.windowMoveEnabled ?? false) && (candidate.windowMoveEnabled ?? false)
        disabledCandidate.windowResizeEnabled =
            (disabledCandidate.windowResizeEnabled ?? false) && (candidate.windowResizeEnabled ?? false)
        if candidate != disabledCandidate,
           let conflict = GestureSettingsValidation.conflict(
               gestures: candidate,
               orientationOverrides: self.monitors.orientationOverrides,
               monitors: monitors
           )
        {
            return conflict
        }
        gestures.apply(candidate)
        return nil
    }

    func updateMonitorOrientation(
        _ orientation: Monitor.Orientation?,
        for monitor: Monitor,
        monitors: [Monitor]
    ) -> TrackpadGestureConflict? {
        var overrides = self.monitors.orientationOverrides
        if let orientation {
            MonitorSettingsStore.update(
                MonitorOrientationSettings(monitorName: monitor.name, orientation: orientation),
                for: monitor,
                in: &overrides
            )
        } else {
            MonitorSettingsStore.remove(for: monitor, from: &overrides)
        }
        if let conflict = GestureSettingsValidation.conflict(
            gestures: gestures.export(),
            orientationOverrides: overrides,
            monitors: monitors
        ) {
            return conflict
        }
        self.monitors.orientationOverrides = overrides
        return nil
    }
}
