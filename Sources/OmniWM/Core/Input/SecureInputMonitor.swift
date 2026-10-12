// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation

private func secureInputNotifyCallback(
    event _: UInt32,
    data _: UnsafeMutableRawPointer?,
    length _: Int,
    context: Int32
) {
    EventIntake.post(.secureInputStateMayHaveChanged(session: UInt32(bitPattern: context)))
}

struct SecureInputHealthFacts: Sendable, Equatable {
    let observed: Bool
    let live: Bool
    let subscribed: Bool
    let notifications: UInt64
}

@MainActor @Observable
final class SecureInputMonitor {
    private static let notificationEvents: [CGSEventType] = [.secureEventInputStarted, .secureEventInputStopped]
    private static var lastSession: UInt32 = 0

    private(set) var isSecureInputActive = false
    private(set) var isSubscribed = false
    private(set) var notificationCount: UInt64 = 0

    private var session: UInt32?
    private var onStateChange: ((Bool) -> Void)?
    var secureInputStateProviderForTests: (() -> Bool)?
    var registerNotification: (CGSEventType, UInt32) -> Bool = { event, session in
        SkyLight.shared.registerNotifyProc(
            event: event,
            callback: secureInputNotifyCallback,
            context: UnsafeMutableRawPointer(bitPattern: UInt(session))
        )
    }

    var unregisterNotification: (CGSEventType, UInt32) -> Bool = { event, session in
        SkyLight.shared.unregisterNotifyProc(
            event: event,
            callback: secureInputNotifyCallback,
            context: UnsafeMutableRawPointer(bitPattern: UInt(session))
        )
    }

    func start(onStateChange: @escaping (Bool) -> Void) {
        stop()
        Self.lastSession &+= 1
        let session = Self.lastSession
        self.session = session
        self.onStateChange = onStateChange
        subscribe(session: session)
        refresh()
    }

    func stop() {
        if let session {
            unsubscribe(session: session)
        }
        session = nil
        onStateChange = nil
        isSecureInputActive = false
    }

    func recordNotification(session: UInt32) -> Bool {
        guard session == self.session else { return false }
        notificationCount &+= 1
        return true
    }

    func refresh() {
        guard let onStateChange else { return }
        let state = secureInputState()
        guard state != isSecureInputActive else { return }
        isSecureInputActive = state
        DiagnosticsEventRecorder.shared.recordLifecycle(name: "secureInput.changed active=\(state)")
        onStateChange(state)
    }

    func healthFacts() -> SecureInputHealthFacts {
        SecureInputHealthFacts(
            observed: isSecureInputActive,
            live: secureInputState(),
            subscribed: isSubscribed,
            notifications: notificationCount
        )
    }

    private func subscribe(session: UInt32) {
        var registered: [CGSEventType] = []
        for event in Self.notificationEvents {
            guard registerNotification(event, session) else { break }
            registered.append(event)
        }
        isSubscribed = registered.count == Self.notificationEvents.count
        if !isSubscribed {
            unregister(registered, session: session)
            FallbackFiringRecorder.shared.note(.input, "secureInputSubscriptionFailed")
        }
        DiagnosticsEventRecorder.shared.recordLifecycle(name: "secureInput.subscribed=\(isSubscribed)")
    }

    private func unsubscribe(session: UInt32) {
        guard isSubscribed else { return }
        unregister(Self.notificationEvents, session: session)
        isSubscribed = false
    }

    private func unregister(_ events: [CGSEventType], session: UInt32) {
        for event in events where !unregisterNotification(event, session) {
            FallbackFiringRecorder.shared.note(.input, "secureInputUnsubscribeFailed")
        }
    }

    private func secureInputState() -> Bool {
        secureInputStateProviderForTests?() ?? IsSecureEventInputEnabled()
    }
}
