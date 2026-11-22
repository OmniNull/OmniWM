// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    var isCarryingWindowByGesture: Bool {
        state.activeInteractionSource == .trackpadGesture && state.isMoving
    }

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
        guard tapInputs.gesturePhase == .idle, let config = trackpadGestureConfig else { return 0 }
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
        if controller?.pointerEdgeBarrier.ownsCrossings == false {
            controller?.mouseWarpHandler.handleMouseWarpMoved(at: location)
            recordMouseWarpSample()
        }
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
        windowIdUnderPointer: Int? = nil,
        windowServerFramesAtMouseDown: [WindowToken: CGRect]? = nil,
        strip: PressedStrip? = nil
    ) -> Bool {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return false
        }
        guard controller != nil, !isCarryingWindowByGesture else { return false }
        controller?.noteUserAction()
        if button == .left {
            state.leftPressLocation = location
            state.leftPressModifiers = modifiers
            state.leftPressWasDragged = false
        }
        let blocked = shouldBlockOwnWindowInput(at: location, windowIdUnderPointer: windowIdUnderPointer)
        if MouseTrace.shared.isActive {
            let geometric = controller?.ownedWindowRegistry.containsGeometric(point: location) ?? false
            MouseTrace.record(
                "tap: down \(button == .right ? "R" : "L") loc=\(TraceFormat.point(location)) "
                    + "ownGeom=\(geometric) ownInteractive=\(blocked) "
                    + "decision=\(blocked ? "yieldToOwned" : "handledByWM")"
            )
        }
        if blocked {
            if controller?.ownedWindowRegistry.contains(point: location, excluding: [.parkingEdgeMask]) == false {
                state.parkingEdgePressButton = button
            }
            return false
        }
        if button == .left {
            clearNativeTitleBarDrag()
        }
        return handleMouseDownFromTap(
            at: location,
            modifiers: modifiers,
            button: button,
            windowIdUnderPointer: windowIdUnderPointer,
            windowServerFramesAtMouseDown: windowServerFramesAtMouseDown,
            strip: strip
        )
    }

    func dispatchMouseDragged(at location: CGPoint, button: MouseButton = .left) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        guard !isCarryingWindowByGesture else { return }
        warpDraggedPointer(at: location)
        controller?.workspaceBarManager.handleAutoHideMouseMoved(at: location)
        confirmNativeMouseDrag(at: location, button: button)
        if ownWindowInterruptsDrag(button, at: location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseDraggedFromTap(at: location, button: button)
    }

    func dispatchMouseUp(at location: CGPoint, button: MouseButton = .left) {
        if button == .left, !isCarryingWindowByGesture {
            releaseEdgeResizeHold()
        }
        if state.parkingEdgePressButton == button {
            state.parkingEdgePressButton = nil
        }
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        guard !isCarryingWindowByGesture else { return }
        if button == .left { state.leftReleaseLocation = location }
        markNativeTitleBarDragFallbackReleased(button: button, at: location)
        finishNativeTitleBarDragIfNeeded(button: button)
        if button == .left {
            endCarriedWindowMove(at: location)
            runDeferredClickScroll()
        }
        if !isCapturedInteraction(button), shouldBlockOwnWindowInput(at: location) {
            cancelActiveMouseInteraction()
            return
        }
        if button == .left, !state.isMoving, !state.isResizing {
            controller?.surfaceReconciler.recheckBorderOrderingAfterMouseUp(at: location)
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
        if tapInputs.capturedOtherMouseButton == button {
            if type == .otherMouseUp {
                tapInputs.capturedOtherMouseButton = nil
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
        tapInputs.capturedOtherMouseButton = button
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
              !nativeTitleBarDragBlocksOverview, !state.awaitsNativeTitleBarDragTarget
        else { return false }
        tapInputs.capturedOtherMouseButton = button
        controller.windowActionHandler.toggleOverview()
        return true
    }

    private func canCaptureOtherMouseButton(_ controller: WMController) -> Bool {
        controller.isEnabled && !isInputSuppressed
            && tapInputs.capturedOtherMouseButton == nil && tapInputs.capturedInteractionButton == nil
            && !state.isMoving && !state.isResizing
    }

    @discardableResult
    func receiveTapMouseDown(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton = .left,
        clickCount: Int64 = 1,
        queuedLeftPress: LeftMouseDownIntake? = nil,
        authoritative: Bool = false
    ) -> Bool {
        if isCarryingWindowByGesture, !isInputSuppressed { return false }
        if let latched = state.parkingEdgePressButton,
           latched == button || pressedMouseButtonsProvider() & latched.pressedMask == 0
        {
            state.parkingEdgePressButton = nil
        }
        let blocked = shouldBlockOwnWindowInput(at: location)
        prepareForMouseDown(button, blocked: blocked, queued: queuedLeftPress != nil)
        var strip = button == .left ? pressedStrip(at: location) : nil
        if button == .left {
            armFusionDoubleClick(at: location, modifiers: modifiers, clickCount: clickCount, in: &strip)
        }
        if authoritative, button == .left, clickCount == 2,
           handleFusionDoubleClick(at: location, modifiers: modifiers)
        {
            return true
        }
        let suppress = dispatchMouseDown(
            at: location,
            modifiers: modifiers,
            button: button,
            windowServerFramesAtMouseDown: queuedLeftPress?.windowServerFrames,
            strip: strip
        )
        if !blocked, let queuedLeftPress, state.awaitsNativeTitleBarDragTarget {
            state.nativeTitleBarDragPressTimestamp = queuedLeftPress.timestamp
            if let target = queuedLeftPress.dragTarget {
                dispatchAnnotatedLeftMouseDragged(at: target.location, windowIdUnderPointer: target.windowId)
            }
        }
        return suppress
    }

    private func prepareForMouseDown(_ button: MouseButton, blocked: Bool, queued: Bool) {
        if blocked {
            if !queued { dropPendingTapMovement() }
            if button == .left, !isInputSuppressed,
               state.nativeTitleBarDrag == nil,
               state.awaitsNativeTitleBarDragTarget,
               state.nativeTitleBarDragFallbackReleased
            {
                retireNativeTitleBarDragAtInputBoundary()
            }
        } else {
            if !queued { flushQueuedTapEventsBeforeImmediateDispatch() }
            if button == .left, !isInputSuppressed {
                state.liveDropScroll = nil
                retireNativeTitleBarDragAtInputBoundary()
            }
        }
    }

    func receiveTapMouseDragged(at location: CGPoint, button: MouseButton = .left) {
        if !isInputSuppressed {
            guard !isCarryingWindowByGesture else { return }
            confirmNativeMouseDrag(at: location, button: button)
        }
        EventIntake.post(.mouseDragged(button: button, location: location))
    }

    func dispatchAnnotatedLeftMouseDragged(at location: CGPoint, windowIdUnderPointer: Int?) {
        guard state.awaitsNativeTitleBarDragTarget else { return }
        if isCapturingPerformance { recordCGEvent(.leftMouseDragged) }
        receiveAnnotatedNativeMouseDragged(at: location, windowIdUnderPointer: windowIdUnderPointer)
    }

    func receiveAnnotatedNativeMouseDragged(at location: CGPoint, windowIdUnderPointer: Int?) {
        guard state.awaitsNativeTitleBarDragTarget,
              state.nativeTitleBarDrag == nil,
              let windowIdUnderPointer,
              let entry = controller?.workspaceManager.entry(forWindowId: windowIdUnderPointer),
              entry.mode == .tiling
        else {
            if state.awaitsNativeTitleBarDragTarget, state.nativeTitleBarDrag == nil {
                let entry = windowIdUnderPointer.flatMap { controller?.workspaceManager.entry(forWindowId: $0) }
                traceLiveDragDecline(
                    "annotated-drag windowUnderPointer=\(windowIdUnderPointer.map(String.init) ?? "nil") "
                        + "managed=\(entry != nil) mode=\(entry.map { "\($0.mode)" } ?? "-") "
                        + "fallback=\(TraceFormat.token(state.nativeTitleBarDragFallbackToken))"
                )
            }
            if windowIdUnderPointer != nil || state.nativeTitleBarDragFallbackReleased {
                rejectNativeTitleBarDragTarget()
            }
            return
        }
        let released = state.nativeTitleBarDragFallbackReleased
        let fallbackToken = state.nativeTitleBarDragFallbackToken
        if released, let fallbackToken, fallbackToken != entry.token {
            retainNativeResizeCorrection(for: fallbackToken)
        }
        correctDeferredNativeResizeFrameIfNeeded(excluding: entry.token)
        state.awaitsNativeTitleBarDragTarget = false
        state.nativeTitleBarDragFallbackToken = nil
        state.nativeTitleBarDragFallbackReleased = false
        state.nativeTitleBarDrag = .init(token: entry.token)
        if let fallbackToken { recheckRetainedNativeResizeCorrection(for: fallbackToken) }
        if state.nativeCrossDisplayMove?.token != entry.token {
            captureNativeCrossDisplayMove(for: entry.token)
        }
        confirmNativeMouseDrag(at: location, button: .left)
        if released { finishNativeTitleBarDragIfNeeded(button: .left) }
    }

    func receiveTapMouseUp(at location: CGPoint, button: MouseButton = .left, drainPendingEvents: Bool = true) {
        if isCarryingWindowByGesture, !isInputSuppressed { return }
        markNativeTitleBarDragFallbackReleased(button: button, at: location)
        defer {
            if tapInputs.capturedInteractionButton == button {
                tapInputs.capturedInteractionButton = nil
            }
        }
        if drainPendingEvents {
            if !isCapturedInteraction(button), shouldBlockOwnWindowInput(at: location) {
                dropPendingTapMovement()
            } else {
                flushQueuedTapEventsBeforeImmediateDispatch()
            }
        }
        dispatchMouseUp(at: location, button: button)
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
        if shouldBlockOwnWindowGestureInput(at: snapshot.location) {
            dropPendingTapMovement()
        } else {
            flushQueuedTapEventsBeforeImmediateDispatch()
        }
        processed = true
        handleGestureEvent(snapshot)
    }

    private func shouldProcessGestureFrame(_ snapshot: GestureEventSnapshot) -> Bool {
        guard tapInputs.gesturePhase == .idle else { return true }
        let activeTouchCount = Self.activeTouchCount(in: snapshot.touches)
        guard activeTouchCount > 0 else {
            state.suppressGestureStartUntilAllTouchesLift = false
            tapInputs.consumeTrackpadScrollUntilAllTouchesLift = false
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
        eventIntake.removePendingMouseEvents(includingButtons: true)
    }

    private func dropPendingTapMovement() {
        eventIntake.removePendingMouseEvents(includingButtons: false)
    }

    private func flushQueuedTapEventsBeforeImmediateDispatch() {
        eventIntake.drainNow()
    }

    func dispatchQueuedMouseDragged(at location: CGPoint, button: MouseButton) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        guard !isCarryingWindowByGesture else { return }
        warpDraggedPointer(at: location)
        controller?.workspaceBarManager.handleAutoHideMouseMoved(at: location)
        confirmNativeMouseDrag(at: location, button: button)
        if ownWindowInterruptsDrag(button, at: location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseDraggedFromTap(at: location, button: button, requirePressedButtonCheck: false)
    }

    private func ownWindowInterruptsDrag(_ button: MouseButton, at location: CGPoint) -> Bool {
        !isCapturedInteraction(button) && !isLiveColumnDragActive && liveDragSession?.carriedWindow == nil
            && shouldBlockOwnWindowInput(at: location)
    }

    private func warpDraggedPointer(at location: CGPoint) {
        guard state.parkingEdgePressButton == nil else { return }
        controller?.mouseWarpHandler.handleMouseWarpMoved(at: location)
        recordMouseWarpSample()
    }
}
