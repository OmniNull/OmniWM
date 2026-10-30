// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import IOKit.pwr_mgt

@MainActor @Observable
final class SleepPreventionManager {
    struct PerformanceSnapshot: Equatable, Sendable {
        let assertionAcquisitions: UInt64
    }

    static let shared = SleepPreventionManager()

    @ObservationIgnored private var sleepAssertionID: IOPMAssertionID?
    @ObservationIgnored private var isUserSessionActive = true
    @ObservationIgnored private var performanceAssertionAcquisitions: UInt64?
    private let now: @MainActor () -> Date
    private let scheduleDeadline: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    private let createAssertion: @MainActor () -> IOPMAssertionID?
    private let releaseAssertion: @MainActor (IOPMAssertionID) -> Void
    private let observesWorkspace: Bool
    @ObservationIgnored private var cancelDeadline: (@MainActor () -> Void)?
    @ObservationIgnored private var awakeSubscriptions: [UUID: @MainActor (ShellAwake) -> Void] = [:]
    private(set) var awake = ShellAwake(on: false, until: nil)

    init(
        now: @escaping @MainActor () -> Date = Date.init,
        scheduleDeadline: @escaping @MainActor (
            TimeInterval, @escaping @MainActor () -> Void
        ) -> (@MainActor () -> Void) = SleepPreventionManager.scheduleDeadline,
        createAssertion: @escaping @MainActor () -> IOPMAssertionID? = SleepPreventionManager.createAssertion,
        releaseAssertion: @escaping @MainActor (IOPMAssertionID) -> Void = SleepPreventionManager.releaseAssertion,
        observeWorkspace: Bool = true
    ) {
        self.now = now
        self.scheduleDeadline = scheduleDeadline
        self.createAssertion = createAssertion
        self.releaseAssertion = releaseAssertion
        observesWorkspace = observeWorkspace
        if observeWorkspace { setupWorkspaceNotifications() }
    }

    isolated deinit {
        cancelDeadline?()
        if let sleepAssertionID { releaseAssertion(sleepAssertionID) }
        if observesWorkspace { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    }

    func perform(_ command: ShellAwakeCommand) {
        let next: ShellAwake
        let duration: TimeInterval?
        switch command {
        case .on:
            next = ShellAwake(on: true, until: nil)
            duration = nil
        case .off:
            next = ShellAwake(on: false, until: nil)
            duration = nil
        case let .timed(minutes):
            guard minutes.isFinite, minutes > 0, minutes <= ShellAwakeCommand.maximumMinutes else { return }
            duration = minutes * 60
            next = ShellAwake(on: true, until: now().timeIntervalSince1970 + minutes * 60)
        }
        cancelDeadline?()
        cancelDeadline = nil
        let changed = next != awake
        awake = next
        if let duration, let until = next.until {
            cancelDeadline = scheduleDeadline(duration) { [weak self] in
                self?.expireAwake(until: until)
            }
        }
        reconcileSleepAssertion()
        if changed { publishAwake() }
    }

    @discardableResult
    func subscribeAwake(_ callback: @escaping @MainActor (ShellAwake) -> Void) -> UUID {
        let token = UUID()
        awakeSubscriptions[token] = callback
        callback(awake)
        return token
    }

    func removeAwakeSubscription(_ token: UUID) {
        awakeSubscriptions.removeValue(forKey: token)
    }

    func setSessionActive(_ active: Bool) {
        isUserSessionActive = active
        reconcileSleepAssertion()
    }

    private func expireAwake(until: Double) {
        guard awake.until == until else { return }
        cancelDeadline = nil
        awake = ShellAwake(on: false, until: nil)
        reconcileSleepAssertion()
        publishAwake()
    }

    private func publishAwake() {
        for callback in awakeSubscriptions.values { callback(awake) }
    }

    private static func scheduleDeadline(
        after duration: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> (@MainActor () -> Void) {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }

    func beginPerformanceCapture() {
        performanceAssertionAcquisitions = 0
    }

    func performanceSnapshot() -> PerformanceSnapshot? {
        performanceAssertionAcquisitions.map {
            PerformanceSnapshot(assertionAcquisitions: $0)
        }
    }

    func endPerformanceCapture() -> PerformanceSnapshot? {
        let snapshot = performanceSnapshot()
        performanceAssertionAcquisitions = nil
        return snapshot
    }

    private func reconcileSleepAssertion() {
        guard awake.on, isUserSessionActive else {
            releaseSleepAssertion()
            return
        }
        guard sleepAssertionID == nil else { return }
        performanceAssertionAcquisitions? &+= 1
        sleepAssertionID = createAssertion()
    }

    private static func createAssertion() -> IOPMAssertionID? {
        var assertionID: IOPMAssertionID = 0
        let reason = "OmniWM prevents sleep" as CFString
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            reason,
            nil,
            nil,
            nil,
            0,
            nil,
            &assertionID
        )

        if result == kIOReturnSuccess {
            return assertionID
        }
        FallbackFiringRecorder.shared.note(.system, "sleepAssertionCreateFailed")
        return nil
    }

    private func releaseSleepAssertion() {
        if let assertionID = sleepAssertionID {
            releaseAssertion(assertionID)
            sleepAssertionID = nil
        }
    }

    private static func releaseAssertion(_ assertionID: IOPMAssertionID) {
        if IOPMAssertionRelease(assertionID) != kIOReturnSuccess {
            FallbackFiringRecorder.shared.note(.system, "sleepAssertionReleaseFailed")
        }
    }

    private func setupWorkspaceNotifications() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )

        notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func sessionDidResignActive() {
        setSessionActive(false)
    }

    @objc private func sessionDidBecomeActive() {
        setSessionActive(true)
    }
}
