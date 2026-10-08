// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    var isInputSuppressed: Bool {
        guard let controller else { return true }
        return controller.isLockScreenActive || controller.isFrontmostAppLockScreen()
    }

    var trackpadGestureConfig: TrackpadGestureIntent.Config? {
        guard let controller else { return nil }
        let settings = controller.settings
        let overviewState = controller.windowActionHandler.overviewState
        let isOverviewOpen = overviewState.isOpen
        return TrackpadGestureIntent.Config(
            columnScrollEnabled: settings.gestures.scrollEnabled && !isOverviewOpen,
            columnScrollFingerCount: settings.gestures.fingerCount.rawValue,
            workspaceSwipeEnabled: settings.gestures.workspaceSwipeEnabled && !isOverviewOpen,
            workspaceSwipeFingerCount: settings.gestures.workspaceSwipeFingerCount.rawValue,
            workspaceSwipeAxis: settings.gestures.workspaceSwipeAxis,
            overviewAction: settings.overview.enabled && settings.gestures.overviewGestureEnabled
                ? overviewState.gestureAction : nil,
            overviewFingerCount: settings.gestures.overviewGestureFingerCount.rawValue,
            windowMoveEnabled: settings.gestures.windowMoveEnabled && !isOverviewOpen,
            windowMoveFingerCount: settings.gestures.windowMoveFingerCount.rawValue,
            windowResizeEnabled: settings.gestures.windowResizeEnabled && !isOverviewOpen,
            windowResizeFingerCount: settings.gestures.windowResizeFingerCount.rawValue
        )
    }

    var steadyTouchFrameFloor: Int {
        guard state.gesturePhase == .idle, let config = trackpadGestureConfig else { return 0 }
        return config.minimumFingerCount
    }

    var overviewGestureInteractive: Bool {
        controller?.motionPolicy.animationsEnabled == true
    }

    func dispatchMouseMoved(
        at location: CGPoint,
        modifiersRawValue: UInt64 = 0,
        windowIdUnderPointer: Int? = nil
    ) {
        state.latestFocusFollowsMouseSample = .init(
            location: location,
            modifiersRawValue: modifiersRawValue,
            windowIdUnderPointer: windowIdUnderPointer
        )
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            resetHoveredEdgesIfNeeded()
            return
        }
        controller?.mouseWarpHandler.handleMouseWarpMoved(at: location)
        recordMouseWarpSample()
        handleMouseMovedFromTap(
            at: location,
            modifiersRawValue: modifiersRawValue,
            windowIdUnderPointer: windowIdUnderPointer
        )
    }

    @discardableResult
    func dispatchMouseDown(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton = .left,
        windowIdUnderPointer: Int? = nil
    ) -> Bool {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return false
        }
        guard controller != nil else { return false }
        let blocked = shouldBlockOwnWindowInput(at: location)
        if MouseTrace.shared.isActive {
            let geometric = controller?.ownedWindowRegistry.containsGeometric(point: location) ?? false
            MouseTrace.record(
                "tap: down \(button == .right ? "R" : "L") loc=\(TraceFormat.point(location)) "
                    + "ownGeom=\(geometric) ownInteractive=\(blocked) "
                    + "decision=\(blocked ? "yieldToOwned" : "handledByWM")"
            )
        }
        if blocked {
            return false
        }
        if button == .left {
            clearNativeTitleBarDrag()
        }
        return handleMouseDownFromTap(
            at: location,
            modifiers: modifiers,
            button: button,
            windowIdUnderPointer: windowIdUnderPointer
        )
    }

    func dispatchMouseDragged(at location: CGPoint, button: MouseButton = .left) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        controller?.mouseWarpHandler.handleMouseWarpMoved(at: location)
        recordMouseWarpSample()
        controller?.workspaceBarManager.handleAutoHideMouseMoved(at: location)
        beginNativeTitleBarDragIfNeeded(button: button)
        if !isCapturedInteraction(button), shouldBlockOwnWindowInput(at: location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseDraggedFromTap(at: location, button: button)
    }

    func dispatchMouseUp(at location: CGPoint, button: MouseButton = .left) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        markNativeTitleBarDragFallbackReleased(button: button)
        finishNativeTitleBarDragIfNeeded(button: button)
        if !isCapturedInteraction(button), shouldBlockOwnWindowInput(at: location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseUpFromTap(at: location, button: button)
    }

    func dispatchScrollWheel(_ payload: MouseScrollIntake) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        handleScrollWheelFromTap(payload)
    }

    func receiveTapMouseMoved(
        at location: CGPoint,
        modifiersRawValue: UInt64,
        windowIdUnderPointer: Int? = nil
    ) {
        EventIntake.post(
            .mouseMoved(
                location: location,
                modifiersRawValue: modifiersRawValue,
                windowIdUnderPointer: windowIdUnderPointer
            )
        )
    }

    func receiveTapOtherMouseButton(type: CGEventType, button: Int64, modifiers: CGEventFlags = []) -> Bool {
        if state.capturedOtherMouseButton == button {
            if type == .otherMouseUp {
                state.capturedOtherMouseButton = nil
            }
            return true
        }
        guard type == .otherMouseDown, let controller else { return false }
        if isOverviewMouseButton(button, controller: controller) {
            return captureOverviewMouseButton(button, controller: controller)
        }
        guard canCaptureOtherMouseButton(controller),
              controller.hotkeys.dispatchMouseButton(button, flags: modifiers)
        else { return false }
        state.capturedOtherMouseButton = button
        return true
    }

    private func isOverviewMouseButton(_ button: Int64, controller: WMController) -> Bool {
        OverviewInputSettingsValidation.mouseButtons.contains(button)
            && controller.settings.overview.enabled
            && controller.settings.overview.mouseButton == button
            && controller.settings.systemHyperTrigger.mouseButtonNumber != button
    }

    private func captureOverviewMouseButton(_ button: Int64, controller: WMController) -> Bool {
        flushQueuedTapEventsBeforeImmediateDispatch()
        guard canCaptureOtherMouseButton(controller), !isTrackpadSwipeSessionActive,
              state.nativeTitleBarDrag == nil, !state.awaitsNativeTitleBarDragTarget
        else { return false }
        state.capturedOtherMouseButton = button
        controller.windowActionHandler.toggleOverview()
        return true
    }

    private func canCaptureOtherMouseButton(_ controller: WMController) -> Bool {
        controller.isEnabled && !isInputSuppressed
            && state.capturedOtherMouseButton == nil && state.capturedInteractionButton == nil
            && !state.isMoving && !state.isResizing
    }

    @discardableResult
    func receiveTapMouseDown(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton = .left
    ) -> Bool {
        if shouldBlockOwnWindowInput(at: location) {
            dropPendingTapEvents()
        } else {
            flushQueuedTapEventsBeforeImmediateDispatch()
            if button == .left, !isInputSuppressed {
                retireNativeTitleBarDragAtInputBoundary()
            }
        }
        return dispatchMouseDown(
            at: location,
            modifiers: modifiers,
            button: button
        )
    }

    func receiveTapMouseDragged(at location: CGPoint, button: MouseButton = .left) {
        if !isInputSuppressed {
            beginNativeTitleBarDragIfNeeded(button: button)
        }
        EventIntake.post(.mouseDragged(button: button, location: location))
    }

    func receiveAnnotatedNativeMouseDragged(windowIdUnderPointer: Int?) {
        guard state.awaitsNativeTitleBarDragTarget,
              state.nativeTitleBarDrag == nil,
              let windowIdUnderPointer,
              let entry = controller?.workspaceManager.entry(forWindowId: windowIdUnderPointer),
              entry.mode == .tiling
        else {
            if windowIdUnderPointer != nil {
                state.awaitsNativeTitleBarDragTarget = false
                state.nativeTitleBarDragFallbackToken = nil
                state.nativeTitleBarDragFallbackReleased = false
            }
            return
        }
        state.awaitsNativeTitleBarDragTarget = false
        state.nativeTitleBarDragFallbackToken = nil
        state.nativeTitleBarDragFallbackReleased = false
        state.nativeTitleBarDrag = .init(token: entry.token)
        beginNativeTitleBarDragIfNeeded(button: .left)
    }

    func receiveTapMouseUp(at location: CGPoint, button: MouseButton = .left) {
        markNativeTitleBarDragFallbackReleased(button: button)
        defer {
            if state.capturedInteractionButton == button {
                state.capturedInteractionButton = nil
            }
        }
        if !isCapturedInteraction(button), shouldBlockOwnWindowInput(at: location) {
            dropPendingTapEvents()
        } else {
            flushQueuedTapEventsBeforeImmediateDispatch()
        }
        dispatchMouseUp(at: location, button: button)
    }

    func receiveTapScrollWheel(
        _ payload: MouseScrollIntake,
        traceMetadata: TrackpadScrollTrace.ScrollMetadata? = nil
    ) -> Bool {
        let traceSender = traceMetadata?.senderId ?? payload.senderId
        let before = TrackpadScrollTrace.shared.isActive ? trackpadTraceState(senderId: traceSender) : nil
        var decision = ScrollDecision.inputSuppressed
        defer {
            if let before {
                TrackpadScrollTrace.record(.scroll(.init(
                    payload: payload, metadata: traceMetadata, decision: decision,
                    before: before, after: trackpadTraceState(senderId: traceSender)
                )))
            }
        }
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return false
        }
        if payload.phase == 0, payload.momentumPhase == 0, payload.isContinuous,
           let senderId = payload.senderId, senderId != 0
        {
            drainTrackpadFrames(for: senderId, at: payload.location)
            if consumesTrackpadSession(senderId: senderId) {
                recordDroppedTrackpadScroll()
                decision = .ownedSession
                return true
            }
        }
        decision = scrollDecision(
            at: payload.location,
            momentumPhase: payload.momentumPhase,
            phase: payload.phase,
            modifiers: payload.modifiers
        )
        let suppress = decision.suppresses
        if suppress, MouseTrace.shared.isActive {
            MouseTrace.record("tap: scroll suppressed loc=\(TraceFormat.point(payload.location))")
        }
        if payload.momentumPhase == 0, payload.phase == 0 {
            EventIntake.post(.mouseScroll(payload))
        } else {
            recordDroppedTrackpadScroll()
        }
        return suppress
    }

    private func scrollDecision(
        at location: CGPoint,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) -> ScrollDecision {
        let isTrackpad = momentumPhase != 0 || phase != 0
        if isTrackpad { return trackpadScrollDecision(momentumPhase: momentumPhase, phase: phase) }

        guard let controller, controller.isEnabled,
              controller.settings.effectiveTrackpadGesturesEnabled
        else {
            return .wheelDisabled
        }
        if controller.isOverviewOpen() { return .overview }
        if shouldBlockOwnWindowInput(at: location) { return .ownWindow }
        guard !state.isResizing, !state.isMoving else { return .windowInteraction }
        guard controller.settings.gestures.scrollEnabled else { return .wheelDisabled }
        let requiredModifiers = controller.settings.gestures.scrollModifierKey.cgEventFlag
        guard Self.mouseWheelModifiersMatch(modifiers, required: requiredModifiers) else { return .modifierMismatch }
        return resolveScrollContext(at: location) != nil ? .wheelBinding : .wheelUnclaimed
    }

    private func trackpadScrollDecision(momentumPhase: UInt32, phase: UInt32) -> ScrollDecision {
        if isTrackpadSwipeSessionActive {
            if phase == CGScrollPhase.began.rawValue { state.suppressTrackpadMomentumScroll = false }
            return .activeGesture
        }
        if state.consumeTrackpadScrollUntilAllTouchesLift { return .liftLatch }
        if state.suppressTrackpadMomentumScroll {
            if momentumPhase != 0 { return .momentumTail }
            if phase == CGScrollPhase.ended.rawValue || phase == CGScrollPhase.cancelled.rawValue {
                return .terminalTail
            }
            guard phase == CGScrollPhase.began.rawValue else { return .momentumTail }
            state.suppressTrackpadMomentumScroll = false
            return .freshPhase
        }
        return .trackpadUnclaimed
    }

    func receiveTapGestureEvent(_ snapshot: GestureEventSnapshot) {
        let before = TrackpadScrollTrace.shared.isActive
            ? trackpadTraceState(senderId: snapshot.contactSession?.senderId) : nil
        var processed = false
        defer {
            if let before {
                TrackpadScrollTrace.record(.gesture(.init(
                    timestamp: snapshot.timestamp, phase: snapshot.phaseRawValue,
                    fingers: Self.activeTouchCount(in: snapshot.touches), contact: snapshot.contactSession,
                    processed: processed, before: before,
                    after: trackpadTraceState(senderId: snapshot.contactSession?.senderId)
                )))
            }
        }
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        guard shouldProcessGestureFrame(snapshot) else { return }
        if shouldBlockOwnWindowInput(at: snapshot.location) {
            dropPendingTapEvents()
        } else {
            flushQueuedTapEventsBeforeImmediateDispatch()
        }
        processed = true
        handleGestureEvent(snapshot)
    }

    private func shouldProcessGestureFrame(_ snapshot: GestureEventSnapshot) -> Bool {
        guard state.gesturePhase == .idle else { return true }
        let activeTouchCount = Self.activeTouchCount(in: snapshot.touches)
        guard activeTouchCount > 0 else {
            state.suppressGestureStartUntilAllTouchesLift = false
            state.consumeTrackpadScrollUntilAllTouchesLift = false
            return true
        }
        if state.suppressGestureStartUntilAllTouchesLift { return false }
        guard let config = trackpadGestureConfig else { return false }
        return TrackpadGestureIntent.allowsGestureStart(config, fingerCount: activeTouchCount)
    }

    nonisolated static func activeTouchCount(in touches: [GestureTouchSample]) -> Int {
        touches.count(where: { $0.phase != .ended && $0.phase != .cancelled })
    }

    func dropPendingTapEvents() {
        controller?.eventIntake.removePendingMouseEvents()
    }

    private func flushQueuedTapEventsBeforeImmediateDispatch() {
        controller?.eventIntake.drainNow()
    }

    func dispatchQueuedMouseDragged(at location: CGPoint, button: MouseButton) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        controller?.mouseWarpHandler.handleMouseWarpMoved(at: location)
        recordMouseWarpSample()
        controller?.workspaceBarManager.handleAutoHideMouseMoved(at: location)
        beginNativeTitleBarDragIfNeeded(button: button)
        if !isCapturedInteraction(button), shouldBlockOwnWindowInput(at: location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseDraggedFromTap(at: location, button: button, requirePressedButtonCheck: false)
    }
}
