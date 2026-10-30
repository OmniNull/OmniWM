// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func commitGestureMode(
        metrics: GestureFrameMetrics,
        lockedContext: MouseInputState.LockedGestureContext,
        timestamp: TimeInterval
    ) -> Bool {
        guard let controller, var config = trackpadGestureConfig else {
            abortActiveGestureIfNeeded()
            return false
        }
        if let axis = lockedContext.workspaceAxis {
            config.workspaceSwipeAxis = axis
        }
        config.overviewAction = controller.settings.overview.enabled ? lockedContext.overviewAction : nil
        guard let mode = TrackpadGestureIntent.resolveMode(
            config,
            fingerCount: lockedContext.fingerCount,
            cumulativeTranslation: CGVector(dx: metrics.cumulativeX, dy: metrics.cumulativeY),
            columnScrollAxis: lockedContext.columnScrollAxis,
            columnContextAvailable: lockedContext.columnScrollCandidate && controller.niriEngine != nil,
            windowContextAvailable: lockedContext.windowGestureTarget != nil
        ) else {
            state.suppressGestureStartUntilAllTouchesLift = true
            resetGestureState()
            return false
        }
        if case .overview = mode, overviewGestureInteractive,
           !controller.windowActionHandler.beginOverviewGesture()
        {
            state.suppressGestureStartUntilAllTouchesLift = true
            resetGestureState()
            return false
        }
        if mode.isWindowInteraction, !beginGestureWindowInteraction(mode, lockedContext: lockedContext) {
            state.suppressGestureStartUntilAllTouchesLift = true
            resetGestureState()
            return false
        }
        MouseTrace.record("gesture: committed \(mode) with \(lockedContext.fingerCount) fingers")
        metrics.traceRecognition(mode, timestamp: timestamp)
        state.activeGestureMode = mode
        state.gesturePhase = .committed
        if case let .workspaceSwitch(axis) = mode {
            controller.layoutRefreshController.workspaceSwipe.begin(
                axis: axis, cumulative: axis == .horizontal ? metrics.cumulativeX : metrics.cumulativeY,
                timestamp: timestamp,
                recognitionMovement: SwipeEvent(
                    delta: Double(axis == .horizontal ? metrics.rawDeltaX : metrics.rawDeltaY),
                    timestamp: metrics.previousTimestamp
                )
            )
            if controller.layoutRefreshController.workspaceSwipe.hasPresentation { state.workspaceSwipeFired = true }
        } else {
            controller.layoutRefreshController.workspaceSwipe.cancel(reason: "other-gesture")
        }
        return true
    }

    func dispatchCommittedGestureFrame(
        metrics: GestureFrameMetrics,
        lockedContext: MouseInputState.LockedGestureContext,
        monitor: Monitor,
        timestamp: TimeInterval
    ) {
        guard let controller else { return }
        switch state.activeGestureMode {
        case let .overview(action):
            handleOverviewSwipe(action, metrics: metrics, timestamp: timestamp)
        case .columnScroll:
            guard let engine = controller.niriEngine else {
                abortActiveGestureIfNeeded()
                return
            }
            let orientation: Monitor.Orientation = lockedContext.columnScrollAxis == .horizontal
                ? .horizontal
                : .vertical
            let primaryDelta = lockedContext.columnScrollAxis == .horizontal
                ? metrics.rawDeltaX
                : metrics.rawDeltaY
            var deltaUnits = primaryDelta * CGFloat(controller.settings.gestures.scrollSensitivity)
            if controller.settings.gestures.invertDirection {
                deltaUnits = -deltaUnits
            }
            applyTrackpadViewportScrollDelta(
                deltaUnits,
                engine: engine,
                wsId: lockedContext.workspaceId,
                monitor: monitor,
                orientation: orientation,
                timestamp: timestamp
            )
        case let .workspaceSwitch(axis):
            dispatchWorkspaceSwipeFrame(
                axis: axis,
                metrics: metrics,
                monitorId: lockedContext.monitorId,
                timestamp: timestamp
            )
        case .windowMove:
            guard state.gestureOwnsWindowInteraction, state.isMoving else {
                abortActiveGestureIfNeeded()
                return
            }
            updateActiveMove(at: gestureWindowLocation(for: lockedContext))
        case .windowResize:
            guard state.gestureOwnsWindowInteraction, state.isResizing else {
                abortActiveGestureIfNeeded()
                return
            }
            updateManagedResize(at: gestureWindowLocation(for: lockedContext))
        case nil:
            abortActiveGestureIfNeeded()
        }
    }

    private func dispatchWorkspaceSwipeFrame(
        axis: WorkspaceSwipeAxis,
        metrics: GestureFrameMetrics,
        monitorId: Monitor.ID,
        timestamp: TimeInterval
    ) {
        guard let controller else { return }
        if controller.layoutRefreshController.workspaceSwipe.update(
            cumulative: axis == .horizontal ? metrics.cumulativeX : metrics.cumulativeY,
            timestamp: timestamp
        ) { return }
        handleWorkspaceSwipeFrame(
            axis: axis,
            cumulative: axis == .horizontal ? metrics.cumulativeX : metrics.cumulativeY,
            monitorId: monitorId
        )
    }

    private func handleOverviewSwipe(
        _ action: OverviewGestureAction,
        metrics: GestureFrameMetrics,
        timestamp: TimeInterval
    ) {
        guard let controller, controller.settings.overview.enabled,
              controller.settings.gestures.overviewGestureEnabled
        else {
            abortActiveGestureIfNeeded()
            return
        }
        if overviewGestureInteractive {
            controller.windowActionHandler.updateOverviewGesture(
                cumulativeUnits: Double(metrics.cumulativeY),
                timestamp: timestamp,
                recognitionMovement: action == .resume ? nil : SwipeEvent(
                    delta: Double(metrics.rawDeltaY), timestamp: metrics.previousTimestamp
                )
            )
            return
        }
        let translation = CGPoint(x: metrics.cumulativeX, y: metrics.cumulativeY)
        guard TrackpadGestureIntent.overviewTriggered(action: action, translation: translation) else { return }
        retainConsumedTrackpadSession()
        state.suppressGestureStartUntilAllTouchesLift = true
        state.consumeTrackpadScrollUntilAllTouchesLift = true
        state.suppressTrackpadMomentumScroll = true
        resetGestureState(settleViewportGesture: false)
        switch action {
        case .open:
            controller.windowActionHandler.openOverview()
        case .close:
            controller.windowActionHandler.dismissOverview()
        case .resume:
            break
        }
    }

    private func handleWorkspaceSwipeFrame(
        axis: WorkspaceSwipeAxis,
        cumulative: CGFloat,
        monitorId: Monitor.ID
    ) {
        guard !state.workspaceSwipeFired,
              abs(cumulative) >= TrackpadGestureIntent.workspaceSwipeTriggerUnits,
              let isNext = TrackpadGestureIntent.isNextWorkspace(
                  axis: axis,
                  displacement: cumulative,
                  naturalDirection: controller?.settings.gestures.invertDirection ?? true
              )
        else { return }
        state.workspaceSwipeFired = true
        controller?.workspaceNavigationHandler.switchWorkspaceBySwipe(isNext: isNext, monitorId: monitorId)
    }

    func finishCommittedGestureOnRelease(timestamp: TimeInterval, allowFlick: Bool) {
        guard let lockedContext = state.lockedGestureContext else {
            assertionFailure("Committed gesture missing locked context")
            return
        }
        switch state.activeGestureMode {
        case .overview:
            controller?.windowActionHandler.endOverviewGesture(timestamp: allowFlick ? timestamp : nil)
            state.suppressTrackpadMomentumScroll = true
        case let .workspaceSwitch(axis):
            finalizeWorkspaceSwipe(
                monitorId: lockedContext.monitorId,
                axis: axis,
                allowFlick: allowFlick,
                timestamp: timestamp
            )
        case .windowMove,
             .windowResize:
            if allowFlick {
                commitGestureWindowInteraction(lockedContext: lockedContext)
            } else {
                cancelGestureWindowInteraction()
            }
        default:
            if let engine = controller?.niriEngine {
                finalizeOrCancelCommittedGesture(
                    using: lockedContext,
                    engine: engine,
                    shouldFocusSelection: allowFlick,
                    timestamp: timestamp
                )
            } else {
                cancelCommittedGestureViewportState(for: lockedContext.workspaceId)
            }
        }
    }

    private func finalizeWorkspaceSwipe(
        monitorId: Monitor.ID,
        axis: WorkspaceSwipeAxis,
        allowFlick: Bool,
        timestamp: TimeInterval
    ) {
        defer { state.suppressTrackpadMomentumScroll = true }
        if controller?.layoutRefreshController.workspaceSwipe
            .release(timestamp: timestamp, allowFlick: allowFlick) == true
        {
            return
        }
        defer {
            TrackpadScrollTrace.record(.workspaceFallback(
                cumulative: Double((axis == .horizontal
                        ? state.gestureLastAverageX - state.gestureStartX
                        : state.gestureLastAverageY - state.gestureStartY)
                    * GestureEventSnapshot.normalizedPositionToGestureUnits),
                velocity: state.workspaceSwipeTracker.velocity(), allowFlick: allowFlick,
                fired: state.workspaceSwipeFired
            ))
        }
        guard allowFlick, !state.workspaceSwipeFired else { return }
        state.workspaceSwipeTracker.push(delta: 0, timestamp: timestamp)
        let cumulative = (axis == .horizontal
            ? state.gestureLastAverageX - state.gestureStartX
            : state.gestureLastAverageY - state.gestureStartY)
            * GestureEventSnapshot.normalizedPositionToGestureUnits
        guard let displacement = TrackpadGestureIntent.releaseFlickDisplacement(
                  cumulativeAxisUnits: cumulative,
                  velocity: state.workspaceSwipeTracker.velocity()
              ),
              let isNext = TrackpadGestureIntent.isNextWorkspace(
                  axis: axis,
                  displacement: displacement,
                  naturalDirection: controller?.settings.gestures.invertDirection ?? true
              )
        else { return }
        state.workspaceSwipeFired = true
        controller?.workspaceNavigationHandler.switchWorkspaceBySwipe(isNext: isNext, monitorId: monitorId)
    }

    func finalizeOrCancelCommittedGesture(
        using lockedContext: MouseInputState.LockedGestureContext,
        engine: NiriLayoutEngine,
        shouldFocusSelection: Bool,
        timestamp: TimeInterval? = nil
    ) {
        guard let controller else { return }
        let wsId = lockedContext.workspaceId
        guard let monitor = controller.workspaceManager.monitor(byId: lockedContext.monitorId) else {
            cancelCommittedGestureViewportState(for: wsId)
            return
        }

        let geometry = controller.niriInteractionGeometry(for: monitor)
        let orientation: Monitor.Orientation = lockedContext.columnScrollAxis == .horizontal
            ? .horizontal
            : .vertical
        let viewportSpan = orientation == .horizontal
            ? geometry.workingFrame.width
            : geometry.workingFrame.height

        guard let sample = controller.workspaceManager.animationDriver.sampleGestureEnd(
            in: wsId,
            isTrackpad: true,
            viewportWidth: Double(viewportSpan),
            timestamp: timestamp
        ) else { return }

        let baseOffset = Double(controller.workspaceManager.niriViewportState(for: wsId).viewOffset)
        let settings = engine.effectiveSettings(in: wsId)

        var selectedWindow: NiriWindow?
        controller.workspaceManager.withNiriViewportState(for: wsId) { endState in
            selectedWindow = engine.endProjectedGesture(
                state: &endState,
                context: NiriInteractionContext(
                    workspaceId: wsId,
                    motion: controller.motionPolicy.snapshot(),
                    workingFrame: geometry.workingFrame,
                    gaps: geometry.innerGap,
                    orientation: orientation
                ),
                currentOffset: baseOffset + sample.relativeOffset,
                projectedOffset: baseOffset + sample.relativeProjectedOffset,
                snapToColumn: controller.settings.gestures.trackpadScrollStyle == .snap,
                centerMode: settings.centerFocusedColumn,
                alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn,
                viewFrame: monitor.frame,
                scale: geometry.scale
            )
        }
        completeTrackpadViewportGesture(selectedWindow, engine: engine, workspaceId: wsId, focus: shouldFocusSelection)
    }

    private func completeTrackpadViewportGesture(
        _ selectedWindow: NiriWindow?, engine: NiriLayoutEngine, workspaceId wsId: WorkspaceDescriptor.ID,
        focus shouldFocusSelection: Bool
    ) {
        guard let controller else { return }
        if let selectedWindow {
            rememberViewportFocusAnchor(selectedWindow, engine: engine, wsId: wsId)
            if shouldFocusSelection {
                focusViewportSelectionAfterGesture(selectedWindow)
            }
        }
        if controller.workspaceManager.animationDriver.hasMotion(in: wsId) {
            controller.layoutRefreshController.startScrollAnimation(for: wsId)
        } else {
            controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
        }
    }

    func finalizeCommittedGestureAfterTouchRelease(timestamp: TimeInterval) {
        retainConsumedTrackpadSession()
        finishCommittedGestureOnRelease(timestamp: timestamp, allowFlick: true)
        state.suppressGestureStartUntilAllTouchesLift = true
        state.consumeTrackpadScrollUntilAllTouchesLift = true
        resetGestureState()
        state.suppressTrackpadMomentumScroll = true
    }

    func cancelCommittedGestureViewportState(
        for wsId: WorkspaceDescriptor.ID,
        requestRelayout: Bool = true
    ) {
        guard let controller else { return }
        let driver = controller.workspaceManager.animationDriver
        let semanticOffset = controller.workspaceManager.niriViewportState(for: wsId).viewOffset
        guard let liveOffset = driver.liveViewOffset(in: wsId, semanticOffset: semanticOffset) else { return }
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            vstate.jumpOffset(to: liveOffset)
            vstate.viewOffsetToRestore = nil
            vstate.activatePrevColumnOnRemoval = nil
        }
        if requestRelayout {
            controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
        }
    }

    func abortActiveGestureIfNeeded() {
        if state.gesturePhase == .committed {
            retainConsumedTrackpadSession()
            if case .overview = state.activeGestureMode {
                state.suppressTrackpadMomentumScroll = true
            } else if case .workspaceSwitch = state.activeGestureMode {
                controller?.layoutRefreshController.workspaceSwipe.cancel(reason: "gesture-aborted")
                state.suppressTrackpadMomentumScroll = true
            } else if state.activeGestureMode?.isWindowInteraction == true {
                cancelGestureWindowInteraction()
            } else if let lockedContext = state.lockedGestureContext {
                if let engine = controller?.niriEngine {
                    finalizeOrCancelCommittedGesture(
                        using: lockedContext,
                        engine: engine,
                        shouldFocusSelection: false
                    )
                } else {
                    cancelCommittedGestureViewportState(for: lockedContext.workspaceId)
                }
            } else {
                assertionFailure("Committed gesture missing locked context")
            }
            state.suppressGestureStartUntilAllTouchesLift = true
            state.consumeTrackpadScrollUntilAllTouchesLift = true
        }
        resetGestureState()
    }

    func resetGestureState(settleViewportGesture: Bool = true) {
        controller?.layoutRefreshController.workspaceSwipe.stopPreparing(warm: true)
        cancelGestureWindowInteraction()
        if state.lockedGestureContext?.overviewAction != nil {
            controller?.windowActionHandler.endOverviewGesture(timestamp: nil)
        }
        if settleViewportGesture,
           let lockedContext = state.lockedGestureContext,
           controller?.workspaceManager.animationDriver.hasGesture(in: lockedContext.workspaceId) == true
        {
            cancelCommittedGestureViewportState(for: lockedContext.workspaceId)
        }
        state.gesturePhase = .idle
        state.gestureStartX = 0.0
        state.gestureStartY = 0.0
        state.gestureLastAverageX = 0.0
        state.gestureLastAverageY = 0.0
        state.gestureLastTimestamp = 0
        state.lockedGestureContext = nil
        state.activeGestureMode = nil
        state.gestureFingerCountMismatchSince = nil
        state.viewportGestureSessionID = nil
        state.workspaceSwipeFired = false
    }
}
