// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import os

struct TapFilterSnapshot: Sendable {
    var activeCapture: MouseEventHandler.MouseButton?
    var claimedOtherButtons: Set<Int64> = []
    var moveModifier: CGEventFlags?
    var resizeModifier: CGEventFlags = []
    var scrollModifier: CGEventFlags = []
    var minGestureFingers: Int = 3
    var gestureActiveOrLatched: Bool = false
    var isInputSuppressed: Bool = false
}

final class InputTapThread: @unchecked Sendable {
    private var thread: Thread?
    private var runLoopRef: CFRunLoop?
    private let condition = NSCondition()
    private var started = false

    private let filterLock = OSAllocatedUnfairLock(initialState: TapFilterSnapshot())
    private let touchCountLock = OSAllocatedUnfairLock<(@Sendable () -> Int)?>(initialState: nil)

    var touchCountProvider: (@Sendable () -> Int)? {
        get { touchCountLock.withLock { $0 } }
        set { touchCountLock.withLock { $0 = newValue } }
    }

    var runLoop: CFRunLoop? {
        condition.lock()
        defer { condition.unlock() }
        return runLoopRef
    }

    var filterSnapshot: TapFilterSnapshot {
        filterLock.withLock { $0 }
    }

    func updateFilterSnapshot(_ mutate: @Sendable (inout TapFilterSnapshot) -> Void) {
        filterLock.withLock(mutate)
    }

    func startAndGetRunLoop() -> CFRunLoop {
        condition.lock()
        defer { condition.unlock() }
        if !started {
            started = true
            let tapThread = Thread { [weak self] in
                guard let self else { return }
                let currentRunLoop = CFRunLoopGetCurrent()
                self.condition.lock()
                self.runLoopRef = currentRunLoop
                self.condition.signal()
                self.condition.unlock()

                var context = CFRunLoopSourceContext()
                if let dummySource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context) {
                    CFRunLoopAddSource(currentRunLoop, dummySource, .commonModes)
                }

                while !Thread.current.isCancelled {
                    let result = CFRunLoopRunInMode(.defaultMode, 1.0e10, false)
                    if result == .stopped || result == .finished {
                        break
                    }
                }
            }
            tapThread.name = "app.omniwm.input-tap"
            tapThread.qualityOfService = .userInteractive
            self.thread = tapThread
            tapThread.start()

            while runLoopRef == nil {
                condition.wait()
            }
        }
        return runLoopRef!
    }

    func stop() {
        condition.lock()
        guard started, let targetThread = thread else {
            condition.unlock()
            return
        }
        let loop = runLoopRef
        started = false
        runLoopRef = nil
        thread = nil
        condition.unlock()

        targetThread.cancel()
        if let loop {
            CFRunLoopStop(loop)
        }
    }

    nonisolated func evaluateTap(type: CGEventType, event: CGEvent) -> CGEvent? {
        let snap = filterSnapshot
        if snap.isInputSuppressed {
            return event
        }

        switch type {
        case .mouseMoved:
            let location = ScreenCoordinateSpace.toAppKit(point: event.location)
            let modifiersRawValue = event.flags.rawValue
            let windowId = MouseEventHandler.eventWindowIdUnderPointer(event)
            EventIntake.post(.mouseMoved(
                location: location,
                modifiersRawValue: modifiersRawValue,
                windowIdUnderPointer: windowId
            ))
            return event

        case .leftMouseDown,
             .leftMouseDragged,
             .leftMouseUp:
            return evaluateLeftMouse(type: type, event: event, snap: snap)

        case .rightMouseDown,
             .rightMouseDragged,
             .rightMouseUp:
            return evaluateRightMouse(type: type, event: event, snap: snap)

        case .otherMouseDown,
             .otherMouseDragged,
             .otherMouseUp:
            return evaluateOtherMouse(type: type, event: event, snap: snap)

        case .scrollWheel:
            return evaluateScrollWheel(event: event, snap: snap)

        default:
            return event
        }
    }

    private nonisolated func evaluateLeftMouse(
        type: CGEventType,
        event: CGEvent,
        snap: TapFilterSnapshot
    ) -> CGEvent? {
        let location = ScreenCoordinateSpace.toAppKit(point: event.location)
        switch type {
        case .leftMouseDown:
            let flags = event.flags
            let isMoveCandidate = MouseEventHandler.mouseMoveMode(modifiers: flags, required: snap.moveModifier) != nil
            guard isMoveCandidate else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        _ = MouseEventHandler._instance?.receiveTapMouseDown(
                            at: location,
                            modifiers: flags,
                            button: .left
                        )
                    }
                }
                return event
            }
            _ = evaluateAuthoritativeTapOnMain(
                type: type, location: location, modifiers: flags, buttonNumber: 0, scrollPayload: nil
            )
            return event
        case .leftMouseDragged:
            guard snap.activeCapture == .left else {
                EventIntake.post(.mouseDragged(button: .left, location: location))
                return event
            }
            let suppress = evaluateAuthoritativeTapOnMain(
                type: type, location: location, modifiers: event.flags, buttonNumber: 0, scrollPayload: nil
            )
            return suppress ? nil : event
        case .leftMouseUp:
            guard snap.activeCapture == .left else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        MouseEventHandler._instance?.receiveTapMouseUp(at: location, button: .left)
                    }
                }
                return event
            }
            let suppress = evaluateAuthoritativeTapOnMain(
                type: type, location: location, modifiers: event.flags, buttonNumber: 0, scrollPayload: nil
            )
            return suppress ? nil : event
        default:
            return event
        }
    }

    private nonisolated func evaluateRightMouse(
        type: CGEventType,
        event: CGEvent,
        snap: TapFilterSnapshot
    ) -> CGEvent? {
        let location = ScreenCoordinateSpace.toAppKit(point: event.location)
        let flags = event.flags
        switch type {
        case .rightMouseDown:
            let isResizeCandidate = !snap.resizeModifier.isEmpty
                && MouseEventHandler.modifierFlagsMatch(flags, required: snap.resizeModifier)
            guard isResizeCandidate else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        _ = MouseEventHandler._instance?.receiveTapMouseDown(
                            at: location,
                            modifiers: flags,
                            button: .right
                        )
                    }
                }
                return event
            }
            let suppress = evaluateAuthoritativeTapOnMain(
                type: type, location: location, modifiers: flags, buttonNumber: 1, scrollPayload: nil
            )
            return suppress ? nil : event
        case .rightMouseDragged:
            guard snap.activeCapture == .right else {
                EventIntake.post(.mouseDragged(button: .right, location: location))
                return event
            }
            let suppress = evaluateAuthoritativeTapOnMain(
                type: type, location: location, modifiers: flags, buttonNumber: 1, scrollPayload: nil
            )
            return suppress ? nil : event
        case .rightMouseUp:
            guard snap.activeCapture == .right else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        MouseEventHandler._instance?.receiveTapMouseUp(at: location, button: .right)
                    }
                }
                return event
            }
            let suppress = evaluateAuthoritativeTapOnMain(
                type: type, location: location, modifiers: flags, buttonNumber: 1, scrollPayload: nil
            )
            return suppress ? nil : event
        default:
            return event
        }
    }

    private nonisolated func evaluateOtherMouse(
        type: CGEventType,
        event: CGEvent,
        snap: TapFilterSnapshot
    ) -> CGEvent? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard snap.claimedOtherButtons.contains(button) else {
            return event
        }
        let location = ScreenCoordinateSpace.toAppKit(point: event.location)
        let suppress = evaluateAuthoritativeTapOnMain(
            type: type, location: location, modifiers: event.flags, buttonNumber: button, scrollPayload: nil
        )
        return suppress ? nil : event
    }

    private nonisolated func evaluateScrollWheel(
        event: CGEvent,
        snap: TapFilterSnapshot
    ) -> CGEvent? {
        let momentumPhase = UInt32(event.getIntegerValueField(.scrollWheelEventMomentumPhase))
        let phase = UInt32(event.getIntegerValueField(.scrollWheelEventScrollPhase))
        let isTrackpad = momentumPhase != 0 || phase != 0
        let location = ScreenCoordinateSpace.toAppKit(point: event.location)
        let flags = event.flags

        if !isTrackpad {
            let isModified = !snap.scrollModifier.isEmpty
                && MouseEventHandler.mouseWheelModifiersMatch(flags, required: snap.scrollModifier)
            guard isModified else {
                let payload = MouseEventHandler.scrollPayload(event, at: location, modifiersRawValue: flags.rawValue)
                EventIntake.post(.mouseScroll(payload.payload))
                return event
            }
            let payload = MouseEventHandler.scrollPayload(event, at: location, modifiersRawValue: flags.rawValue)
            let suppress = evaluateAuthoritativeTapOnMain(
                type: .scrollWheel, location: location, modifiers: flags, buttonNumber: 0, scrollPayload: payload
            )
            return suppress ? nil : event
        }

        let touches = touchCountProvider?() ?? 0
        let isGestureCandidate = snap.gestureActiveOrLatched || touches >= snap.minGestureFingers
        guard isGestureCandidate else {
            return event
        }
        let payload = MouseEventHandler.scrollPayload(event, at: location, modifiersRawValue: flags.rawValue)
        let suppress = evaluateAuthoritativeTapOnMain(
            type: .scrollWheel, location: location, modifiers: flags, buttonNumber: 0, scrollPayload: payload
        )
        return suppress ? nil : event
    }

    private nonisolated func evaluateAuthoritativeTapOnMain(
        type: CGEventType,
        location: CGPoint,
        modifiers: CGEventFlags,
        buttonNumber: Int64,
        scrollPayload: (payload: MouseScrollIntake, traceMetadata: TrackpadScrollTrace.ScrollMetadata?)?
    ) -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                MouseEventHandler._instance?.dispatchAuthoritativeTap(
                    type: type,
                    location: location,
                    modifiers: modifiers,
                    buttonNumber: buttonNumber,
                    scrollPayload: scrollPayload
                ) ?? false
            }
        }

        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                MouseEventHandler._instance?.dispatchAuthoritativeTap(
                    type: type,
                    location: location,
                    modifiers: modifiers,
                    buttonNumber: buttonNumber,
                    scrollPayload: scrollPayload
                ) ?? false
            }
        }
    }
}
