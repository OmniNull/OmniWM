// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import os

struct TapFilterSnapshot: Sendable {
    var activeCapture: MouseEventHandler.MouseButton?
    var claimedOtherButtonMask: UInt32 = 0
    var moveModifier: CGEventFlags?
    var adoptNativeResize = false
    var resizeModifier: CGEventFlags = []
    var scrollModifier: CGEventFlags = []
    var minGestureFingers: Int = 3
    var gestureActiveOrLatched: Bool = false
    var isInputSuppressed: Bool = false
}

private struct TouchCountProviderBox: Sendable {
    var provider: (@Sendable () -> Int)?
}

final class InputTapThread: @unchecked Sendable {
    private var thread: Thread?
    private var runLoopRef: CFRunLoop?
    private var sessionTapRef: CFMachPort?
    private let condition = NSCondition()
    private var started = false

    private let filterLock = OSAllocatedUnfairLock(initialState: TapFilterSnapshot())
    private let touchCountLock = OSAllocatedUnfairLock(initialState: TouchCountProviderBox())

    var touchCountProvider: (@Sendable () -> Int)? {
        get { touchCountLock.withLock { $0.provider } }
        set { touchCountLock.withLock { $0.provider = newValue } }
    }

    var runLoop: CFRunLoop? {
        condition.lock()
        defer { condition.unlock() }
        return runLoopRef
    }

    var sessionTap: CFMachPort? {
        get { condition.withLock { sessionTapRef } }
        set { condition.withLock { sessionTapRef = newValue } }
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
        sessionTapRef = nil
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
            evaluateLeftMouseDown(
                at: location, modifiers: event.flags, snapshot: snap, captureWindowFrames: Self.captureWindowFrames
            )
            return event
        case .leftMouseDragged:
            guard snap.activeCapture == .left else {
                EventIntake.post(.mouseDragged(button: .left, location: location))
                return event
            }
            return forwardCapturedDrag(event, type: type, location: location, buttonNumber: 0)
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
            return forwardCapturedDrag(event, type: type, location: location, buttonNumber: 1)
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
        guard MouseButtonBinding.supportedButtons.contains(button),
              snap.claimedOtherButtonMask & (UInt32(1) << button) != 0
        else {
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

extension InputTapThread {
    nonisolated func evaluateLeftMouseDown(
        at location: CGPoint,
        modifiers: CGEventFlags,
        snapshot: TapFilterSnapshot,
        captureWindowFrames: () -> [WindowToken: CGRect]
    ) {
        let isMoveCandidate = MouseEventHandler.mouseMoveModifiersMatch(modifiers, required: snapshot.moveModifier)
        if isMoveCandidate {
            _ = evaluateAuthoritativeTapOnMain(
                type: .leftMouseDown, location: location, modifiers: modifiers, buttonNumber: 0, scrollPayload: nil
            )
            return
        }
        let needsNativeResizeBaseline = snapshot.adoptNativeResize
            && modifiers.isDisjoint(with: MouseEventHandler.relevantModifierFlags)
        let windowServerFrames = needsNativeResizeBaseline ? captureWindowFrames() : [:]
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                _ = MouseEventHandler._instance?.receiveTapMouseDown(
                    at: location, modifiers: modifiers, windowServerFramesAtMouseDown: windowServerFrames
                )
            }
        }
    }

    private nonisolated static func captureWindowFrames() -> [WindowToken: CGRect] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }
        var frames: [WindowToken: CGRect] = [:]
        frames.reserveCapacity(windows.count)
        for window in windows {
            guard let windowId = window[kCGWindowNumber as String] as? Int,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            frames[WindowToken(pid: pid, windowId: windowId)] = frame
        }
        return frames
    }

    private nonisolated func forwardCapturedDrag(
        _ event: CGEvent,
        type: CGEventType,
        location: CGPoint,
        buttonNumber: Int64
    ) -> CGEvent? {
        let flags = event.flags
        guard !Thread.isMainThread else {
            let suppress = evaluateAuthoritativeTapOnMain(
                type: type, location: location, modifiers: flags, buttonNumber: buttonNumber, scrollPayload: nil
            )
            return suppress ? nil : event
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                _ = MouseEventHandler._instance?.dispatchAuthoritativeTap(
                    type: type, location: location, modifiers: flags, buttonNumber: buttonNumber, scrollPayload: nil
                )
            }
        }
        return nil
    }
}
