// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    nonisolated static func sessionEventMask(annotatedMoveTapInstalled: Bool) -> CGEventMask {
        var mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)
        if !annotatedMoveTapInstalled {
            mask |= 1 << CGEventType.mouseMoved.rawValue
        }
        return mask
    }

    nonisolated static func annotatedMoveEventMask(includesMouseMoved: Bool) -> CGEventMask {
        let dragged: CGEventMask = 1 << CGEventType.leftMouseDragged.rawValue
        return includesMouseMoved ? dragged | 1 << CGEventType.mouseMoved.rawValue : dragged
    }

    var mouseMovesNeeded: Bool {
        guard let controller else { return true }
        return controller.focusFollowsMouseEnabled
            || controller.workspaceBarManager.needsAutoHideMouseMoves
            || controller.workspaceBarManager.needsShellEdgeMouseMoves
            || (controller.settings.pointer.enabled && controller.workspaceManager.monitors.count > 1)
    }

    func setup() {
        tearDownEventTaps()
        MouseEventHandler._instance = self

        let annotatedMoveTapInstalled = installAnnotatedMoveTap()
        installSessionTap(annotatedMoveTapInstalled: annotatedMoveTapInstalled)

        controller?.settings.onTrackpadGestureAvailabilityChanged = { [weak self] _ in
            self?.reconcileMultitouchSource()
        }
        controller?.settings.onPointerSettingsChanged = { [weak self] in
            self?.reconcileMouseMoveSubscription()
            self?.syncTapFilterSnapshot()
        }
        reconcileMultitouchSource()
        syncTapFilterSnapshot()
    }

    func reconcileMouseMoveSubscription() {
        guard state.moveTap != nil, state.moveTapDeliversMouseMoved != mouseMovesNeeded else { return }
        state.latestFocusFollowsMouseSample = nil
        controller?.resetMouseWarpTransientState()
        tearDownMoveEventTap()
        if !installAnnotatedMoveTap() {
            setup()
        }
    }

    private func installAnnotatedMoveTap() -> Bool {
        let moveCallback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                InputTapHealth.recordTapDisabled(mouse: true, byTimeout: type == .tapDisabledByTimeout)
                if let tap = MouseEventHandler._instance?.state.moveTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            if type == .leftMouseDragged, Thread.isMainThread {
                MainActor.assumeIsolated {
                    guard let handler = MouseEventHandler._instance,
                          handler.state.awaitsNativeTitleBarDragTarget
                    else { return }
                    if handler.isCapturingPerformance {
                        handler.recordCGEvent(type)
                    }
                    handler.receiveAnnotatedNativeMouseDragged(
                        windowIdUnderPointer: MouseEventHandler.eventWindowIdUnderPointer(event)
                    )
                }
            } else {
                _ = MouseEventHandler.processTapCallback(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        return installAnnotatedMoveTap(callback: moveCallback)
    }

    private func installAnnotatedMoveTap(callback: CGEventTapCallBack) -> Bool {
        let includesMouseMoved = mouseMovesNeeded
        state.moveTap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.annotatedMoveEventMask(includesMouseMoved: includesMouseMoved),
            callback: callback,
            userInfo: nil
        )
        state.moveTapDeliversMouseMoved = includesMouseMoved

        var annotatedMoveTapInstalled = false
        if let tap = state.moveTap {
            if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
                state.moveTapRunLoopSource = source
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                annotatedMoveTapInstalled = true
            } else {
                tearDownMoveEventTap()
                FallbackFiringRecorder.shared.note(.input, "mouseMoveTapRunLoopSourceFailed")
            }
        } else {
            FallbackFiringRecorder.shared.note(.input, "mouseMoveTapCreateFailed")
        }
        DiagnosticsEventRecorder.shared.recordLifecycle(
            name: annotatedMoveTapInstalled ? "mouse.moveTap.installed" : "mouse.moveTap.failed"
        )

        return annotatedMoveTapInstalled
    }

    private func installSessionTap(annotatedMoveTapInstalled: Bool) {
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                InputTapHealth.recordTapDisabled(mouse: true, byTimeout: type == .tapDisabledByTimeout)
                if let tap = MouseEventHandler._instance?.state.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                Task { @MainActor in
                    MouseEventHandler._instance?.recoverAfterTapDisable()
                }
                return Unmanaged.passUnretained(event)
            }

            guard let evaluated = MouseEventHandler.processTap(type: type, event: event) else {
                return nil
            }

            return Unmanaged.passUnretained(evaluated)
        }
        installSessionTap(annotatedMoveTapInstalled: annotatedMoveTapInstalled, callback: callback)
    }

    private func installSessionTap(annotatedMoveTapInstalled: Bool, callback: CGEventTapCallBack) {
        let eventMask = Self.sessionEventMask(annotatedMoveTapInstalled: annotatedMoveTapInstalled)

        state.eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: nil
        )

        if let tap = state.eventTap {
            state.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = state.runLoopSource {
                let tapRunLoop = inputTapThread.startAndGetRunLoop()
                state.eventTapRunLoop = tapRunLoop
                CFRunLoopAddSource(tapRunLoop, source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                tearDownSessionEventTap()
                FallbackFiringRecorder.shared.note(.input, "mouseTapRunLoopSourceFailed")
            }
        } else {
            FallbackFiringRecorder.shared.note(.input, "mouseTapCreateFailed")
        }
        DiagnosticsEventRecorder.shared.recordLifecycle(
            name: state.eventTap != nil ? "mouse.tap.installed" : "mouse.tap.failed"
        )
    }

    func tearDownEventTaps() {
        tearDownMoveEventTap()
        tearDownSessionEventTap()
    }

    private func tearDownMoveEventTap() {
        var tap = state.moveTap
        var source = state.moveTapRunLoopSource
        EventTapTeardown.tearDown(tap: &tap, runLoopSource: &source)
        state.moveTap = tap
        state.moveTapRunLoopSource = source
    }

    private func tearDownSessionEventTap() {
        var tap = state.eventTap
        var source = state.runLoopSource
        let runLoop = state.eventTapRunLoop ?? CFRunLoopGetMain()!
        EventTapTeardown.tearDown(tap: &tap, runLoopSource: &source, runLoop: runLoop)
        state.eventTap = tap
        state.runLoopSource = source
        state.eventTapRunLoop = nil
    }

    nonisolated static func processTap(type: CGEventType, event: CGEvent) -> CGEvent? {
        guard let handler = MouseEventHandler._instance else { return event }
        return handler.inputTapThread.evaluateTap(type: type, event: event)
    }

    nonisolated static func processTapCallback(
        type: CGEventType,
        event: CGEvent,
        isMainThread _: Bool = Thread.isMainThread
    ) -> Bool {
        processTap(type: type, event: event) == nil
    }

    func dispatchAuthoritativeTap(
        type: CGEventType,
        location: CGPoint,
        modifiers: CGEventFlags,
        buttonNumber: Int64,
        scrollPayload: (payload: MouseScrollIntake, traceMetadata: TrackpadScrollTrace.ScrollMetadata?)?
    ) -> Bool {
        if isCapturingPerformance { recordCGEvent(type) }

        switch type {
        case .leftMouseDown:
            return receiveTapMouseDown(at: location, modifiers: modifiers, button: .left)
        case .leftMouseDragged:
            let suppress = isCapturedInteraction(.left)
            receiveTapMouseDragged(at: location, button: .left)
            return suppress
        case .leftMouseUp:
            let suppress = isCapturedInteraction(.left)
            receiveTapMouseUp(at: location, button: .left)
            return suppress
        case .rightMouseDown:
            return receiveTapMouseDown(at: location, modifiers: modifiers, button: .right)
        case .rightMouseDragged:
            let suppress = isCapturedInteraction(.right)
            receiveTapMouseDragged(at: location, button: .right)
            return suppress
        case .rightMouseUp:
            let suppress = isCapturedInteraction(.right)
            receiveTapMouseUp(at: location, button: .right)
            return suppress
        case .otherMouseDown,
             .otherMouseDragged,
             .otherMouseUp:
            if type == .otherMouseDragged, !isInputSuppressed {
                controller?.workspaceBarManager.handleAutoHideMouseMoved(at: location)
            }
            return receiveTapOtherMouseButton(type: type, button: buttonNumber, modifiers: modifiers)
        case .scrollWheel:
            guard let scrollPayload else { return false }
            return receiveTapScrollWheel(scrollPayload.payload, traceMetadata: scrollPayload.traceMetadata)
        default:
            return false
        }
    }

    nonisolated static func scrollPayload(
        _ event: CGEvent, at screenLocation: CGPoint, modifiersRawValue: UInt64
    ) -> (payload: MouseScrollIntake, traceMetadata: TrackpadScrollTrace.ScrollMetadata?) {
        let observedAt = TrackpadScrollTrace.shared.isActive ? DispatchTime.now().uptimeNanoseconds : nil
        let momentumPhase = UInt32(event.getIntegerValueField(.scrollWheelEventMomentumPhase))
        let phase = UInt32(event.getIntegerValueField(.scrollWheelEventScrollPhase))
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let needsSender = momentumPhase == 0 && phase == 0 && isContinuous
        let sender = needsSender || observedAt != nil ? scrollSender(event) : (nil, .notRequested)
        let traceMetadata = observedAt.map {
            TrackpadScrollTrace.ScrollMetadata(
                eventTimestamp: event.timestamp, observedAt: $0, senderId: sender.0, senderLookup: sender.1
            )
        }
        let payload = MouseScrollIntake(
            location: screenLocation,
            deltaX: resolvedWheelAxisDelta(
                pointDelta: CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)),
                fixedPointDelta: CGFloat(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)),
                isContinuous: isContinuous
            ),
            deltaY: resolvedWheelAxisDelta(
                pointDelta: CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)),
                fixedPointDelta: CGFloat(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)),
                isContinuous: isContinuous
            ),
            momentumPhase: momentumPhase,
            phase: phase,
            modifiersRawValue: modifiersRawValue,
            isContinuous: isContinuous,
            senderId: needsSender ? sender.0 : nil
        )
        return (payload, traceMetadata)
    }

    private nonisolated static func scrollSender(
        _ event: CGEvent
    ) -> (UInt64?, TrackpadScrollTrace.SenderLookup) {
        guard let hidEvent = CGEventCopyIOHIDEvent(event)?.takeRetainedValue() else { return (nil, .unavailable) }
        let sender = IOHIDEventGetSenderID(hidEvent)
        return sender == 0 ? (nil, .zero) : (sender, .identified)
    }

    nonisolated static func eventWindowIdUnderPointer(_ event: CGEvent) -> Int? {
        let routedWindowId = event.getIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
        )
        if routedWindowId != 0 {
            return normalizedEventWindowId(routedWindowId)
        }
        return normalizedEventWindowId(
            event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        )
    }

    nonisolated static func normalizedEventWindowId(_ value: Int64) -> Int? {
        guard let windowId = UInt32(exactly: value), windowId != 0 else { return nil }
        return Int(windowId)
    }
}
