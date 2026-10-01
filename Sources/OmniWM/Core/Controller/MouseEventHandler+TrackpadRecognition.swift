// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

private let niriTouchpadGestureRecognitionThreshold: CGFloat = 16.0

extension MouseEventHandler {
    struct GestureFrameMetrics {
        var cumulativeX: CGFloat
        var cumulativeY: CGFloat
        var rawDeltaX: CGFloat
        var rawDeltaY: CGFloat
        var previousTimestamp: TimeInterval

        func traceRecognition(_ mode: TrackpadGestureMode, timestamp: TimeInterval) {
            TrackpadScrollTrace.record(.recognition(
                mode: mode, x: Double(cumulativeX), y: Double(cumulativeY),
                dx: Double(rawDeltaX), dy: Double(rawDeltaY), interval: timestamp - previousTimestamp
            ))
        }
    }

    func handleGestureEvent(_ snapshot: GestureEventSnapshot) {
        let location = snapshot.location
        let phase = NSEvent.Phase(rawValue: snapshot.phaseRawValue)
        let activeTouchCount = Self.activeTouchCount(in: snapshot.touches)

        if phase == .ended || phase == .cancelled {
            retainConsumedTrackpadSession()
            defer {
                clearGestureLatches()
                resetGestureState()
            }
            guard gestureFramePreconditionsSatisfied(at: location) else { return }
            if state.gesturePhase == .committed {
                finishCommittedGestureOnRelease(timestamp: snapshot.timestamp, allowFlick: phase == .ended)
            }
            return
        }

        guard gestureFramePreconditionsSatisfied(at: location) else { return }

        if phase == .began, state.gesturePhase != .idle {
            abortActiveGestureIfNeeded()
        }

        guard !snapshot.touches.isEmpty else {
            abortActiveGestureIfNeeded()
            return
        }

        let requiredFingers = state.lockedGestureContext?.fingerCount ?? activeTouchCount
        guard let averageTouchPosition = Self.averageGestureTouchPosition(
            requiredFingers: requiredFingers,
            touches: snapshot.touches
        ) else {
            handleGestureFingerCountMismatch(
                activeTouchCount: activeTouchCount,
                requiredFingers: requiredFingers,
                snapshot: snapshot
            )
            return
        }
        state.gestureFingerCountMismatchSince = nil

        if state.gesturePhase == .idle {
            armGestureIfPossible(
                at: location,
                activeTouchCount: activeTouchCount,
                average: averageTouchPosition,
                timestamp: snapshot.timestamp
            )
            state.lockedGestureContext?.contactSession = snapshot.contactSession
            return
        }
        processActiveGestureFrame(average: averageTouchPosition, timestamp: snapshot.timestamp)
    }

    private func handleGestureFingerCountMismatch(
        activeTouchCount: Int,
        requiredFingers: Int,
        snapshot: GestureEventSnapshot
    ) {
        if state.gesturePhase == .committed {
            let since = state.gestureFingerCountMismatchSince ?? snapshot.timestamp
            state.gestureFingerCountMismatchSince = since
            let held = snapshot.timestamp - since
            if activeTouchCount > 0, held < (state.activeGestureMode?.fingerCountGrace ?? 0) {
                return
            }
            MouseTrace.record("gesture: \(requiredFingers) -> \(activeTouchCount) fingers, ending")
            TrackpadScrollTrace.record(.termination(
                reason: "finger-count", required: requiredFingers, fingers: activeTouchCount, held: held
            ))
            if activeTouchCount < requiredFingers {
                finalizeCommittedGestureAfterTouchRelease(timestamp: snapshot.timestamp)
                return
            }
        } else if state.gesturePhase == .armed, activeTouchCount > requiredFingers,
                  state.lockedGestureContext?.overviewAction == nil,
                  let config = trackpadGestureConfig,
                  TrackpadGestureIntent.windowGestureMode(config, fingerCount: activeTouchCount) != nil,
                  let average = Self.averageGestureTouchPosition(
                      requiredFingers: activeTouchCount,
                      touches: snapshot.touches
                  )
        {
            MouseTrace.record("gesture: re-arm \(requiredFingers) -> \(activeTouchCount) fingers")
            resetGestureState()
            armGestureIfPossible(
                at: snapshot.location,
                activeTouchCount: activeTouchCount,
                average: average,
                timestamp: snapshot.timestamp
            )
            state.lockedGestureContext?.contactSession = snapshot.contactSession
            return
        }
        let wasOverviewCandidate = state.lockedGestureContext?.overviewAction != nil
        if state.gesturePhase == .armed {
            TrackpadScrollTrace.record(.termination(
                reason: "uncommitted-finger-count", required: requiredFingers, fingers: activeTouchCount, held: 0
            ))
        }
        abortActiveGestureIfNeeded()
        if wasOverviewCandidate {
            state.suppressGestureStartUntilAllTouchesLift = true
        }
    }

    private func gestureFramePreconditionsSatisfied(at location: CGPoint) -> Bool {
        guard let controller else { return false }
        guard controller.isEnabled,
              controller.settings.effectiveTrackpadGesturesEnabled
        else {
            abortActiveGestureIfNeeded()
            return false
        }
        let isOverviewOpen = controller.isOverviewOpen()
        if let context = state.lockedGestureContext {
            let invalid: Bool
            if let action = context.overviewAction {
                let tracking = action == .resume
                    || (overviewGestureInteractive && state.activeGestureMode == .overview(action))
                invalid = tracking
                    ? !controller.windowActionHandler.isOverviewGestureActive
                    : action != trackpadGestureConfig?.overviewAction
            } else {
                invalid = isOverviewOpen
            }
            if invalid {
                abortActiveGestureIfNeeded()
                state.suppressGestureStartUntilAllTouchesLift = true
                return false
            }
        }
        if !isOverviewOpen, shouldBlockOwnWindowInput(at: location) {
            abortActiveGestureIfNeeded()
            return false
        }
        if state.isResizing || state.isMoving, !state.gestureOwnsWindowInteraction {
            abortActiveGestureIfNeeded()
            return false
        }
        return true
    }

    private func armGestureIfPossible(
        at location: CGPoint,
        activeTouchCount: Int,
        average: CGPoint,
        timestamp: TimeInterval
    ) {
        guard let context = resolveGestureArmContext(at: location, fingerCount: activeTouchCount) else {
            if let config = trackpadGestureConfig,
               TrackpadGestureIntent.windowGestureMode(config, fingerCount: activeTouchCount) != nil
            {
                state.suppressGestureStartUntilAllTouchesLift = true
            }
            return
        }
        MouseTrace.record("gesture: armed \(activeTouchCount) fingers at \(TraceFormat.point(location))")
        state.lockedGestureContext = context
        if context.workspaceAxis != nil {
            state.workspaceSwipeTracker.reset()
            state.workspaceSwipeTracker.push(delta: 0, timestamp: timestamp)
        }
        state.gestureStartX = average.x
        state.gestureStartY = average.y
        state.gestureLastAverageX = average.x
        state.gestureLastAverageY = average.y
        state.gestureLastTimestamp = timestamp
        state.gesturePhase = .armed
        if context.overviewAction == .resume {
            _ = controller?.windowActionHandler.beginOverviewGesture()
        }
        if let axis = context.workspaceAxis,
           controller?.layoutRefreshController.workspaceSwipe.prepare(
               monitorId: context.monitorId, timestamp: timestamp
           ) == true
        {
            state.gesturePhase = .committed
            state.activeGestureMode = .workspaceSwitch(axis: axis)
            state.workspaceSwipeFired = true
        }
    }

    private func resolveGestureArmContext(
        at location: CGPoint,
        fingerCount: Int
    ) -> MouseInputState.LockedGestureContext? {
        guard let controller, let config = trackpadGestureConfig else { return nil }
        guard let monitor = location.monitorApproximation(in: controller.workspaceManager.monitors),
              let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        else { return nil }
        let layoutType = controller.settings.workspaces.layoutType(for: workspace.name)
        let supportsColumnScroll = supportsNiriColumnScroll(in: workspace)
        let target = TrackpadGestureIntent.windowGestureMode(config, fingerCount: fingerCount) != nil
            ? windowGestureTarget(at: location, wsId: workspace.id, layoutType: layoutType) : nil
        guard TrackpadGestureIntent.hasCandidateMode(
            config,
            fingerCount: fingerCount,
            columnContextAvailable: supportsColumnScroll,
            windowContextAvailable: target != nil
        ) else { return nil }
        let columnScrollCandidate = config.columnScrollEnabled
            && fingerCount == config.columnScrollFingerCount
            && supportsColumnScroll
        let isWorkspaceCandidate = config.workspaceSwipeEnabled && fingerCount == config.workspaceSwipeFingerCount
        let columnScrollAxis = gestureColumnScrollAxis(
            workspaceId: workspace.id,
            monitor: monitor,
            supportsColumnScroll: supportsColumnScroll
        )
        let workspaceAxis: WorkspaceSwipeAxis? = if isWorkspaceCandidate {
            TrackpadGestureIntent.effectiveWorkspaceSwipeAxis(
                config,
                columnScrollAxis: supportsColumnScroll ? columnScrollAxis : nil
            )
        } else {
            nil
        }
        return .init(
            workspaceId: workspace.id,
            monitorId: monitor.id,
            fingerCount: fingerCount,
            columnScrollCandidate: columnScrollCandidate,
            columnScrollAxis: columnScrollAxis,
            workspaceAxis: workspaceAxis,
            overviewAction: fingerCount == config.overviewFingerCount ? config.overviewAction : nil,
            windowGestureTarget: target,
            startLocation: location
        )
    }

    private func processActiveGestureFrame(average: CGPoint, timestamp: TimeInterval) {
        guard let controller else { return }
        guard let lockedContext = state.lockedGestureContext else {
            assertionFailure("Active gesture missing locked context")
            abortActiveGestureIfNeeded()
            return
        }
        guard let monitor = controller.workspaceManager.monitor(byId: lockedContext.monitorId) else {
            abortActiveGestureIfNeeded()
            return
        }

        let metrics = GestureFrameMetrics(
            cumulativeX: (average.x - state.gestureStartX) * GestureEventSnapshot.normalizedPositionToGestureUnits,
            cumulativeY: (average.y - state.gestureStartY) * GestureEventSnapshot.normalizedPositionToGestureUnits,
            rawDeltaX: (average.x - state.gestureLastAverageX) * GestureEventSnapshot.normalizedPositionToGestureUnits,
            rawDeltaY: (average.y - state.gestureLastAverageY) * GestureEventSnapshot.normalizedPositionToGestureUnits,
            previousTimestamp: state.gestureLastTimestamp
        )

        if let axis = lockedContext.workspaceAxis,
           state.gesturePhase == .armed || state.activeGestureMode == .workspaceSwitch(axis: axis)
        {
            state.workspaceSwipeTracker.push(
                delta: Double(axis == .horizontal ? metrics.rawDeltaX : metrics.rawDeltaY),
                timestamp: timestamp
            )
        }

        if state.gesturePhase == .armed {
            let distanceSquared = metrics.cumulativeX * metrics.cumulativeX
                + metrics.cumulativeY * metrics.cumulativeY
            let thresholdSquared = niriTouchpadGestureRecognitionThreshold * niriTouchpadGestureRecognitionThreshold
            guard distanceSquared >= thresholdSquared else {
                state.gestureLastAverageX = average.x
                state.gestureLastAverageY = average.y
                state.gestureLastTimestamp = timestamp
                return
            }
            guard commitGestureMode(metrics: metrics, lockedContext: lockedContext, timestamp: timestamp)
            else { return }
        }

        state.gestureLastAverageX = average.x
        state.gestureLastAverageY = average.y
        state.gestureLastTimestamp = timestamp
        dispatchCommittedGestureFrame(
            metrics: metrics,
            lockedContext: lockedContext,
            monitor: monitor,
            timestamp: timestamp
        )
    }

    static func averageGestureTouchPosition(
        requiredFingers: Int,
        touches: [GestureTouchSample]
    ) -> CGPoint? {
        guard requiredFingers > 0 else { return nil }

        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        var touchCount = 0
        var activeCount = 0

        for touch in touches {
            if touch.phase == .ended || touch.phase == .cancelled {
                continue
            }

            touchCount += 1
            if touchCount > requiredFingers {
                return nil
            }

            guard let normalizedPosition = touch.normalizedPosition else {
                return nil
            }

            sumX += normalizedPosition.x
            sumY += normalizedPosition.y
            activeCount += 1
        }

        guard touchCount == requiredFingers, activeCount > 0 else { return nil }

        return CGPoint(
            x: sumX / CGFloat(activeCount),
            y: sumY / CGFloat(activeCount)
        )
    }
}
