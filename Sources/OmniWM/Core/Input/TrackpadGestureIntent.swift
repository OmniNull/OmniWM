// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum OverviewGestureAction: Equatable {
    case open
    case close
    case resume

    var direction: CGFloat {
        switch self {
        case .open: 1
        case .close: -1
        case .resume: 0
        }
    }

    func accepts(verticalTranslation: CGFloat) -> Bool {
        direction == 0 ? verticalTranslation != 0 : verticalTranslation * direction > 0
    }
}

enum TrackpadGestureMode: Equatable {
    case overview(OverviewGestureAction)
    case columnScroll
    case workspaceSwitch(axis: WorkspaceSwipeAxis)
    case windowMove
    case windowResize

    var isWindowInteraction: Bool {
        switch self {
        case .windowMove,
             .windowResize: true
        case .overview,
             .columnScroll,
             .workspaceSwitch: false
        }
    }

    var fingerCountGrace: TimeInterval {
        isWindowInteraction ? 0.15 : 0
    }
}

enum TrackpadGestureIntent {
    private static let overviewSwipeTriggerUnits: CGFloat = 24.0
    static let overviewTravelUnits = 300.0

    static func overviewTriggered(action: OverviewGestureAction, translation: CGPoint) -> Bool {
        let displacement = translation.y * action.direction
        return displacement >= overviewSwipeTriggerUnits && displacement > abs(translation.x)
    }

    static func overviewProgress(units: Double) -> Double {
        units / overviewTravelUnits
    }

    struct Config: Equatable {
        var columnScrollEnabled: Bool
        var columnScrollFingerCount: Int
        var workspaceSwipeEnabled: Bool
        var workspaceSwipeFingerCount: Int
        var workspaceSwipeAxis: WorkspaceSwipeAxis
        var overviewAction: OverviewGestureAction?
        var overviewFingerCount: Int = 4
        var windowMoveEnabled = false
        var windowMoveFingerCount = 4
        var windowResizeEnabled = false
        var windowResizeFingerCount = 3

        var minimumFingerCount: Int {
            var minimum = Int.max
            if columnScrollEnabled { minimum = min(minimum, columnScrollFingerCount) }
            if workspaceSwipeEnabled { minimum = min(minimum, workspaceSwipeFingerCount) }
            if overviewAction != nil { minimum = min(minimum, overviewFingerCount) }
            if windowMoveEnabled { minimum = min(minimum, windowMoveFingerCount) }
            if windowResizeEnabled { minimum = min(minimum, windowResizeFingerCount) }
            return minimum == .max ? 0 : minimum
        }
    }

    static let workspaceSwipeTriggerUnits: CGFloat = 140.0
    static let workspaceSwipeReleaseVelocityFloor: Double = 800.0

    static func effectiveWorkspaceSwipeAxis(
        _ config: Config,
        columnScrollAxis: WorkspaceSwipeAxis?
    ) -> WorkspaceSwipeAxis {
        if config.columnScrollEnabled,
           config.columnScrollFingerCount == config.workspaceSwipeFingerCount,
           let columnScrollAxis
        {
            return columnScrollAxis == .horizontal ? .vertical : .horizontal
        }
        return config.workspaceSwipeAxis
    }

    static func overviewConflict(_ config: Config, columnScrollAxis: WorkspaceSwipeAxis?) -> TrackpadGestureMode? {
        guard config.overviewAction == .open else { return nil }
        if config.columnScrollEnabled,
           config.columnScrollFingerCount == config.overviewFingerCount,
           columnScrollAxis == .vertical
        {
            return .columnScroll
        }
        if config.workspaceSwipeEnabled,
           config.workspaceSwipeFingerCount == config.overviewFingerCount,
           effectiveWorkspaceSwipeAxis(config, columnScrollAxis: columnScrollAxis) == .vertical
        {
            return .workspaceSwitch(axis: .vertical)
        }
        return nil
    }

    static func windowGestureConflict(_ config: Config, mode: TrackpadGestureMode) -> TrackpadGestureMode? {
        let fingerCount: Int
        switch mode {
        case .windowMove:
            guard config.windowMoveEnabled else { return nil }
            fingerCount = config.windowMoveFingerCount
            if config.windowResizeEnabled, config.windowResizeFingerCount == fingerCount { return .windowResize }
        case .windowResize:
            guard config.windowResizeEnabled else { return nil }
            fingerCount = config.windowResizeFingerCount
            if config.windowMoveEnabled, config.windowMoveFingerCount == fingerCount { return .windowMove }
        case .overview,
             .columnScroll,
             .workspaceSwitch:
            return nil
        }
        if config.columnScrollEnabled, config.columnScrollFingerCount == fingerCount { return .columnScroll }
        if config.workspaceSwipeEnabled, config.workspaceSwipeFingerCount == fingerCount {
            return .workspaceSwitch(axis: config.workspaceSwipeAxis)
        }
        if let action = config.overviewAction, config.overviewFingerCount == fingerCount { return .overview(action) }
        return nil
    }

    private static func requestedWindowGestureMode(_ config: Config, fingerCount: Int) -> TrackpadGestureMode? {
        if config.windowMoveEnabled, fingerCount == config.windowMoveFingerCount { return .windowMove }
        if config.windowResizeEnabled, fingerCount == config.windowResizeFingerCount { return .windowResize }
        return nil
    }

    static func windowGestureMode(_ config: Config, fingerCount: Int) -> TrackpadGestureMode? {
        guard let mode = requestedWindowGestureMode(config, fingerCount: fingerCount),
              windowGestureConflict(config, mode: mode) == nil
        else { return nil }
        return mode
    }

    static func allowsGestureStart(_ config: Config, fingerCount: Int) -> Bool {
        if let mode = requestedWindowGestureMode(config, fingerCount: fingerCount) {
            return windowGestureConflict(config, mode: mode) == nil
        }
        return (config.overviewAction != nil && fingerCount == config.overviewFingerCount)
            || (config.columnScrollEnabled && fingerCount == config.columnScrollFingerCount)
            || (config.workspaceSwipeEnabled && fingerCount == config.workspaceSwipeFingerCount)
    }

    static func hasCandidateMode(
        _ config: Config,
        fingerCount: Int,
        columnContextAvailable: Bool,
        windowContextAvailable: Bool = false
    ) -> Bool {
        if let mode = requestedWindowGestureMode(config, fingerCount: fingerCount) {
            return windowContextAvailable && windowGestureConflict(config, mode: mode) == nil
        }
        return (config.overviewAction != nil && fingerCount == config.overviewFingerCount)
            || (config.columnScrollEnabled && fingerCount == config.columnScrollFingerCount && columnContextAvailable)
            || (config.workspaceSwipeEnabled && fingerCount == config.workspaceSwipeFingerCount)
    }

    static func resolveMode(
        _ config: Config,
        fingerCount: Int,
        cumulativeTranslation: CGVector,
        columnScrollAxis: WorkspaceSwipeAxis,
        columnContextAvailable: Bool,
        windowContextAvailable: Bool = false
    ) -> TrackpadGestureMode? {
        if let mode = requestedWindowGestureMode(config, fingerCount: fingerCount) {
            return windowContextAvailable && windowGestureConflict(config, mode: mode) == nil ? mode : nil
        }
        let dominantAxis: WorkspaceSwipeAxis = abs(cumulativeTranslation.dx) > abs(cumulativeTranslation.dy) ?
            .horizontal : .vertical
        let columnCandidate = config.columnScrollEnabled
            && fingerCount == config.columnScrollFingerCount
            && columnContextAvailable
        let workspaceCandidate = config.workspaceSwipeEnabled && fingerCount == config.workspaceSwipeFingerCount
        let contextAxis = columnContextAvailable ? columnScrollAxis : nil
        let workspaceAxis = effectiveWorkspaceSwipeAxis(config, columnScrollAxis: contextAxis)
        if let action = config.overviewAction, fingerCount == config.overviewFingerCount,
           dominantAxis == .vertical, action.accepts(verticalTranslation: cumulativeTranslation.dy)
        {
            guard overviewConflict(config, columnScrollAxis: contextAxis) == nil else { return nil }
            return .overview(action)
        }
        if columnCandidate, dominantAxis == columnScrollAxis {
            return .columnScroll
        }
        guard workspaceCandidate, workspaceAxis == dominantAxis else { return nil }
        return .workspaceSwitch(axis: workspaceAxis)
    }

    static func windowGestureLocation(
        start: CGPoint,
        startTouch: CGPoint,
        currentTouch: CGPoint,
        monitorFrame: CGRect,
        sensitivity: CGFloat,
        clampToMonitor: Bool = true
    ) -> CGPoint {
        let x = start.x + (currentTouch.x - startTouch.x) * monitorFrame.width * sensitivity
        let y = start.y + (currentTouch.y - startTouch.y) * monitorFrame.height * sensitivity
        guard clampToMonitor else { return CGPoint(x: x, y: y) }
        return CGPoint(
            x: x.clamped(to: monitorFrame.minX ... (monitorFrame.maxX - 1)),
            y: y.clamped(to: monitorFrame.minY ... (monitorFrame.maxY - 1))
        )
    }

    static func isNextWorkspace(
        axis: WorkspaceSwipeAxis,
        displacement: CGFloat,
        naturalDirection: Bool
    ) -> Bool? {
        guard displacement != 0 else { return nil }
        switch axis {
        case .horizontal:
            return naturalDirection ? displacement < 0 : displacement > 0
        case .vertical:
            return naturalDirection ? displacement > 0 : displacement < 0
        }
    }

    static func releaseFlickDisplacement(cumulativeAxisUnits: CGFloat, velocity: Double) -> CGFloat? {
        guard abs(velocity) >= workspaceSwipeReleaseVelocityFloor else { return nil }
        if cumulativeAxisUnits != 0, (velocity > 0) != (cumulativeAxisUnits > 0) {
            return nil
        }
        return CGFloat(velocity)
    }
}
