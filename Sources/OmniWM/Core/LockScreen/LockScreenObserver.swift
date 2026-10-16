// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics
import Foundation

@MainActor
final class LockScreenObserver {
    static let lockScreenAppBundleId = "com.apple.loginwindow"

    enum LockState {
        case unlocked
        case locked
        case transitioning
    }

    private enum ObserverEvent: Sendable {
        case locked
        case unlocked
        case appActivated
    }

    private(set) var state: LockState = .unlocked

    var onLockDetected: (() -> Void)?
    var onUnlockDetected: (() -> Void)?
    var screenLockedProvider: @MainActor () -> Bool? = {
        LockScreenObserver.currentSessionScreenIsLocked()
    }

    private var activationObserver: NSObjectProtocol?
    private var screenLockObserver: NSObjectProtocol?
    private var screenUnlockObserver: NSObjectProtocol?
    private var screenIsLocked = false
    private var observerGeneration = 0
    private var transitionGeneration = 0

    init() {}

    static func currentSessionScreenIsLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    func start() {
        guard screenLockObserver == nil else { return }
        observerGeneration &+= 1
        setupObservers(generation: observerGeneration)
        guard let isLocked = screenLockedProvider() else { return }
        if isLocked {
            handleLockEvent()
        } else {
            handleUnlockEvent()
        }
    }

    func stop() {
        cleanup()
    }

    private func setupObservers(generation: Int) {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.enqueueObserverEvent(.appActivated, generation: generation)
        }

        let dnc = DistributedNotificationCenter.default()

        screenLockObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.enqueueObserverEvent(.locked, generation: generation)
        }

        screenUnlockObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.enqueueObserverEvent(.unlocked, generation: generation)
        }
    }

    private nonisolated func enqueueObserverEvent(_ event: ObserverEvent, generation: Int) {
        Task { @MainActor [weak self] in
            guard let self, generation == observerGeneration else { return }
            switch event {
            case .locked:
                handleLockEvent()
            case .unlocked:
                handleUnlockEvent()
            case .appActivated:
                reconcileMissedUnlock()
            }
        }
    }

    func enqueueLockEventForTests() {
        enqueueObserverEvent(.locked, generation: observerGeneration)
    }

    private func reconcileMissedUnlock() {
        guard screenIsLocked, screenLockedProvider() == false else { return }
        handleUnlockEvent()
    }

    private func handleLockEvent() {
        screenIsLocked = true
        guard state != .locked else { return }
        transitionGeneration &+= 1
        state = .locked
        onLockDetected?()
    }

    func handleUnlockEvent() {
        screenIsLocked = false
        guard state == .locked else { return }
        transitionGeneration &+= 1
        let generation = transitionGeneration
        state = .transitioning
        onUnlockDetected?()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if self.state == .transitioning, generation == self.transitionGeneration {
                self.state = .unlocked
            }
        }
    }

    func isFrontmostAppLockScreen() -> Bool {
        screenIsLocked
    }

    func cleanup() {
        observerGeneration &+= 1
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
        let dnc = DistributedNotificationCenter.default()
        if let observer = screenLockObserver {
            dnc.removeObserver(observer)
            screenLockObserver = nil
        }
        if let observer = screenUnlockObserver {
            dnc.removeObserver(observer)
            screenUnlockObserver = nil
        }
    }
}
