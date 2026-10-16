// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

func axCallbackObserverKey(_ observer: AXObserver) -> UInt {
    UInt(bitPattern: Unmanaged.passUnretained(observer).toOpaque())
}

extension AppAXContext {
    nonisolated static func destroyNotificationRefcon(for windowId: Int) -> UnsafeMutableRawPointer? {
        guard windowId > 0 else { return nil }
        return UnsafeMutableRawPointer(bitPattern: windowId)
    }

    nonisolated static func destroyNotificationWindowId(
        from refcon: UnsafeMutableRawPointer?
    ) -> Int? {
        guard let refcon else { return nil }
        let windowId = Int(bitPattern: refcon)
        guard windowId > 0 else { return nil }
        return windowId
    }

    nonisolated static func handleWindowDestroyedCallback(
        pid: pid_t,
        element: AXUIElement,
        observerKey: UInt,
        callbackGeneration: UInt64?,
        refcon: UnsafeMutableRawPointer?,
        registry: AXCallbackGenerationRegistry = appAXCallbackGenerationRegistry,
        postEvent: (IntakeEvent) -> Void = { EventIntake.post($0) }
    ) {
        guard let windowId = destroyNotificationWindowId(from: refcon) else {
            assertionFailure("Received AX destroy callback without a valid windowId refcon")
            return
        }
        registry.performIfCurrentWindowNotification(
            observerKey: observerKey,
            windowId: windowId,
            element: element,
            notification: .destroyed
        ) {
            postEvent(
                .axWindow(.windowDestroyed(
                    pid: pid,
                    axRef: AXWindowRef(element: element, windowId: windowId),
                    callbackGeneration: callbackGeneration
                ))
            )
        }
    }

    nonisolated static func handleWindowMinimizedCallback(
        pid: pid_t,
        axRef: AXWindowRef,
        minimized: Bool,
        observerKey: UInt,
        callbackGeneration: UInt64?,
        registry: AXCallbackGenerationRegistry = appAXCallbackGenerationRegistry,
        postEvent: (IntakeEvent) -> Void = { EventIntake.post($0) }
    ) {
        registry.performIfCurrentWindowNotification(
            observerKey: observerKey,
            windowId: axRef.windowId,
            element: axRef.element,
            notification: minimized ? .miniaturized : .deminiaturized
        ) {
            let event: AXWindowIntakeEvent = minimized
                ? .windowMiniaturized(pid: pid, axRef: axRef, callbackGeneration: callbackGeneration)
                : .windowDeminiaturized(pid: pid, axRef: axRef, callbackGeneration: callbackGeneration)
            postEvent(.axWindow(event))
        }
    }
}

func axWindowNotificationCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    let notificationName = notification as String
    let observerKey = axCallbackObserverKey(observer)
    let callbackGeneration = appAXCallbackGenerationRegistry.generation(observerKey: observerKey)

    var pid: pid_t = 0
    let pidStatus = AXUIElementGetPid(element, &pid)
    RawAXNotificationTrace.record(
        name: notificationName,
        pid: pid,
        windowId: refcon.map { Int(bitPattern: $0) },
        callbackGeneration: callbackGeneration
    )

    let isDestroyed = notificationName == (kAXUIElementDestroyedNotification as String)
    let isMiniaturized = notificationName == (kAXWindowMiniaturizedNotification as String)
    let isDeminiaturized = notificationName == (kAXWindowDeminiaturizedNotification as String)
    guard isDestroyed || isMiniaturized || isDeminiaturized else { return }
    guard pidStatus == .success else { return }

    DiagnosticsEventRecorder.shared.recordLifecycle(name: notificationName, pid: pid)
    if isDestroyed {
        AppAXContext.handleWindowDestroyedCallback(
            pid: pid,
            element: element,
            observerKey: observerKey,
            callbackGeneration: callbackGeneration,
            refcon: refcon
        )
    } else {
        guard let windowId = AppAXContext.destroyNotificationWindowId(from: refcon) else {
            assertionFailure("Received AX minimization callback without a valid windowId refcon")
            return
        }
        AppAXContext.handleWindowMinimizedCallback(
            pid: pid,
            axRef: AXWindowRef(element: element, windowId: windowId),
            minimized: isMiniaturized,
            observerKey: observerKey,
            callbackGeneration: callbackGeneration
        )
    }
}

func axApplicationNotificationCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _: UnsafeMutableRawPointer?
) {
    let name = notification as String
    if name == (kAXTitleChangedNotification as String) {
        axTitleChangedCallback(observer, element)
        return
    }
    guard name == (kAXFocusedWindowChangedNotification as String) else { return }

    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }

    let observerKey = axCallbackObserverKey(observer)
    let callbackGeneration = appAXCallbackGenerationRegistry.generation(observerKey: observerKey)
    RawAXNotificationTrace.record(
        name: kAXFocusedWindowChangedNotification as String,
        pid: pid,
        windowId: nil,
        callbackGeneration: callbackGeneration
    )
    DiagnosticsEventRecorder.shared.recordLifecycle(name: kAXFocusedWindowChangedNotification as String, pid: pid)

    appAXCallbackGenerationRegistry.performIfCurrent(observerKey: observerKey) {
        EventIntake.post(
            .axWindow(.focusedWindowChanged(
                pid: pid,
                callbackGeneration: callbackGeneration
            ))
        )
    }
}

private func axTitleChangedCallback(_ observer: AXObserver, _ element: AXUIElement) {
    var pid: pid_t = 0
    var windowId: CGWindowID = 0
    guard AXUIElementGetPid(element, &pid) == .success,
          _AXUIElementGetWindow(element, &windowId) == .success,
          windowId != 0
    else {
        return
    }
    let observerKey = axCallbackObserverKey(observer)
    let callbackGeneration = appAXCallbackGenerationRegistry.generation(observerKey: observerKey)
    appAXCallbackGenerationRegistry.performIfCurrent(observerKey: observerKey) {
        EventIntake.post(
            .axWindow(.titleChanged(pid: pid, windowId: windowId, callbackGeneration: callbackGeneration))
        )
    }
}
