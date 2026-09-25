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

    func setup() {
        tearDownEventTaps()
        MouseEventHandler._instance = self

        let annotatedMoveTapInstalled = installAnnotatedMoveTap()
        installSessionTap(annotatedMoveTapInstalled: annotatedMoveTapInstalled)

        controller?.settings.onTrackpadGestureAvailabilityChanged = { [weak self] _ in
            self?.reconcileMultitouchSource()
        }
        reconcileMultitouchSource()
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
        state.moveTap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: (1 << CGEventType.mouseMoved.rawValue)
                | (1 << CGEventType.leftMouseDragged.rawValue),
            callback: callback,
            userInfo: nil
        )

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

            let suppressEvent = MouseEventHandler.processTapCallback(type: type, event: event)

            return suppressEvent ? nil : Unmanaged.passUnretained(event)
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
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
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
        EventTapTeardown.tearDown(tap: &tap, runLoopSource: &source)
        state.eventTap = tap
        state.runLoopSource = source
    }

    private nonisolated static func processTapCallback(
        type: CGEventType,
        event: CGEvent,
        isMainThread: Bool = Thread.isMainThread
    ) -> Bool {
        guard isMainThread else { return false }

        let location = event.location
        let screenLocation = ScreenCoordinateSpace.toAppKit(point: location)
        let modifiers = event.flags
        let windowIdUnderPointer = type == .mouseMoved ? eventWindowIdUnderPointer(event) : nil
        let buttonNumber = type == .otherMouseDown || type == .otherMouseDragged || type == .otherMouseUp
            ? event.getIntegerValueField(.mouseEventButtonNumber) : nil
        let scrollPayload = type == .scrollWheel ? Self.scrollPayload(
            event,
            at: screenLocation,
            modifiersRawValue: modifiers.rawValue
        ) : nil
        return MainActor.assumeIsolated {
            guard let handler = MouseEventHandler._instance else { return false }
            if handler.isCapturingPerformance { handler.recordCGEvent(type) }
            if let buttonNumber {
                return handler.receiveTapOverviewMouseButton(type: type, button: buttonNumber)
            }
            return handler.dispatchTapEvent(
                type: type, location: screenLocation, modifiers: modifiers,
                windowIdUnderPointer: windowIdUnderPointer, scrollPayload: scrollPayload
            )
        }
    }

    private func dispatchTapEvent(
        type: CGEventType, location: CGPoint, modifiers: CGEventFlags,
        windowIdUnderPointer: Int?,
        scrollPayload: (payload: MouseScrollIntake, traceMetadata: TrackpadScrollTrace.ScrollMetadata?)?
    ) -> Bool {
        var suppressEvent = false
        switch type {
        case .mouseMoved:
            receiveTapMouseMoved(
                at: location,
                modifiersRawValue: modifiers.rawValue,
                windowIdUnderPointer: windowIdUnderPointer
            )
        case .leftMouseDown:
            _ = receiveTapMouseDown(at: location, modifiers: modifiers)
        case .leftMouseDragged:
            suppressEvent = isCapturedInteraction(.left)
            receiveTapMouseDragged(at: location)
        case .leftMouseUp:
            suppressEvent = isCapturedInteraction(.left)
            receiveTapMouseUp(at: location)
        case .rightMouseDown:
            suppressEvent = receiveTapMouseDown(
                at: location,
                modifiers: modifiers,
                button: .right
            )
        case .rightMouseDragged:
            suppressEvent = isCapturedInteraction(.right)
            receiveTapMouseDragged(at: location, button: .right)
        case .rightMouseUp:
            suppressEvent = isCapturedInteraction(.right)
            receiveTapMouseUp(at: location, button: .right)
        case .scrollWheel:
            guard let scrollPayload else { return false }
            suppressEvent = receiveTapScrollWheel(scrollPayload.payload, traceMetadata: scrollPayload.traceMetadata)
        default:
            break
        }
        return suppressEvent
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
