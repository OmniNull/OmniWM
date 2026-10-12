// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreHID
import Foundation
import IOKit
import os
import Synchronization

@MainActor
final class MultitouchGestureSource {
    private enum EpisodeReplacementState {
        case notRequested
        case pending
        case completed
    }

    var onSnapshot: ((MouseEventHandler.GestureEventSnapshot) -> Void)?
    var onSourceWillReplace: (() -> Void)?
    var onContactSessions: ((MultitouchContactSessions) -> Void)?

    private static var nextRegistrationGeneration: UInt = 0
    private let operations: LifecycleOperations?
    private let topologyMonitor: MultitouchTopologyMonitor
    private let coalescingDelay: Duration
    private let wakeSettlingDelay: Duration
    private let retryDelays: [Duration]
    nonisolated let rawFrameMailbox = MultitouchFrameMailbox()

    private let devices: MultitouchDeviceRegistration
    private var activeGeneration: UInt = 0
    private var previousActiveCount = 0
    private var revalidationTask: Task<Void, Never>?
    private var episodeActive = false
    private var episodeReasons: Set<RevalidationReason> = []
    private var episodeBaselineDeviceIds: Set<UInt64> = []
    private var retryEpisode: UInt64 = 0
    private var retryAttempt = 0
    private var nextRetryDelay: Duration?
    private var retryExhausted = false
    private var wakeSettlingArmed = false
    private var episodeReplacementState: EpisodeReplacementState = .notRequested
    private var revalidationSchedule: UInt64 = 0

    private var state: LifecycleState = .stopped
    private var lastTopologySignal: TopologySignal?
    private var lastEnumeration: MultitouchBinding.EnumerationOutcome?
    private var lastRawCallbackTimestamp: Double?
    private var lastRawCallbackGeneration: UInt?
    private var lastAcceptedCallbackTimestamp: Double?
    private var lastAcceptedCallbackGeneration: UInt?

    init() {
        let operations = MultitouchBinding().map(LifecycleOperations.init(binding:))
        self.operations = operations
        devices = MultitouchDeviceRegistration(operations: operations, callback: Self.contactCallback)
        coalescingDelay = .milliseconds(100)
        wakeSettlingDelay = .seconds(1)
        let retryDelays: [Duration] = [
            .milliseconds(250),
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
            .seconds(4),
            .seconds(8)
        ]
        self.retryDelays = retryDelays
        topologyMonitor = MultitouchTopologyMonitor(
            operations: MultitouchTopologyMonitor.liveOperations,
            retryDelays: retryDelays
        )
    }

    init(
        operations: LifecycleOperations?,
        topologyMonitoringEnabled: Bool = false,
        topologyMonitoringOperations: TopologyMonitoringOperations? = nil,
        coalescingDelay: Duration = .milliseconds(100),
        wakeSettlingDelay: Duration = .seconds(1),
        retryDelays: [Duration] = [
            .milliseconds(250),
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
            .seconds(4),
            .seconds(8)
        ]
    ) {
        self.operations = operations
        devices = MultitouchDeviceRegistration(operations: operations, callback: Self.contactCallback)
        topologyMonitor = MultitouchTopologyMonitor(
            operations: topologyMonitoringEnabled
                ? topologyMonitoringOperations ?? MultitouchTopologyMonitor.liveOperations
                : nil,
            retryDelays: retryDelays
        )
        self.coalescingDelay = coalescingDelay
        self.wakeSettlingDelay = wakeSettlingDelay
        self.retryDelays = retryDelays
    }

    deinit {
        revalidationTask?.cancel()
    }

    @discardableResult
    func startLifecycle() -> Bool {
        guard state == .stopped else { return MultitouchGestureSource.shared === self }
        if let current = MultitouchGestureSource.shared, current !== self {
            guard current.shutdown() else { return false }
        }
        MultitouchGestureSource.shared = self
        guard operations != nil else {
            state = .unavailable
            return true
        }
        state = .waiting
        topologyMonitor.start(source: self)
        requestRevalidation(.startup)
        return true
    }

    func suspendForSleep() {
        guard state != .stopped else { return }
        cancelRevalidation()
        invalidateActiveGeneration()
        _ = teardownRegistrations(resetGestureState: true)
        state = .suspended
    }

    func requestRevalidation(_ reason: RevalidationReason) {
        guard operations != nil, state != .stopped, state != .unavailable else { return }
        if state == .suspended, reason != .wake, reason != .unlock {
            return
        }
        if topologyMonitor.topologyObserverState == .exhausted,
           reason == .startup || reason == .wake || reason == .unlock
        {
            topologyMonitor.start(source: self)
        }
        if !episodeActive {
            episodeActive = true
            episodeReasons.removeAll(keepingCapacity: true)
            episodeBaselineDeviceIds = devices.registryIds
            retryEpisode &+= 1
            retryAttempt = 0
            retryExhausted = false
            episodeReplacementState = .notRequested
        }
        let introducedWakeSettling = (reason == .wake || reason == .unlock)
            && !episodeReasons.contains(.wake)
            && !episodeReasons.contains(.unlock)
        episodeReasons.insert(reason)
        let requestsReplacement = reason == .wake || reason == .unlock || reason == .arrival || reason == .removal
        if requestsReplacement, episodeReplacementState == .notRequested {
            episodeReplacementState = .pending
        }
        if introducedWakeSettling, retryAttempt == 0, revalidationTask != nil, !wakeSettlingArmed {
            revalidationTask?.cancel()
            revalidationTask = nil
            scheduleRevalidation(after: wakeSettlingDelay, settlesWake: true)
            return
        }
        let isTopologySignal = reason == .arrival || reason == .removal
        if isTopologySignal,
           revalidationTask != nil,
           !wakeSettlingArmed,
           let nextRetryDelay,
           nextRetryDelay > coalescingDelay
        {
            revalidationTask?.cancel()
            revalidationTask = nil
            scheduleRevalidation(after: coalescingDelay)
            return
        }
        guard revalidationTask == nil else { return }
        let needsWakeSettling = episodeReasons.contains(.wake) || episodeReasons.contains(.unlock)
        scheduleRevalidation(
            after: needsWakeSettling ? wakeSettlingDelay : coalescingDelay,
            settlesWake: needsWakeSettling
        )
    }

    @discardableResult
    func shutdown() -> Bool {
        revalidationTask?.cancel()
        revalidationTask = nil
        revalidationSchedule &+= 1
        topologyMonitor.cancel()
        episodeActive = false
        episodeReasons.removeAll(keepingCapacity: false)
        episodeBaselineDeviceIds.removeAll(keepingCapacity: false)
        nextRetryDelay = nil
        retryExhausted = false
        wakeSettlingArmed = false
        episodeReplacementState = .notRequested
        invalidateActiveGeneration()
        let cleanedUp = teardownRegistrations(resetGestureState: true)
        topologyMonitor.finishStop()
        state = .stopped
        if cleanedUp, MultitouchGestureSource.shared === self {
            MultitouchGestureSource.shared = nil
        }
        return cleanedUp
    }

    func receiveTopologySignal(_ signal: TopologySignal) {
        lastTopologySignal = signal
        requestRevalidation(signal == .arrival ? .arrival : .removal)
    }

    private func scheduleRevalidation(after delay: Duration, settlesWake: Bool = false) {
        guard episodeActive, revalidationTask == nil, let operations else { return }
        nextRetryDelay = delay
        wakeSettlingArmed = settlesWake
        if activeGeneration == 0 {
            state = retryAttempt == 0 ? .waiting : .retrying
        }
        let episode = retryEpisode
        revalidationSchedule &+= 1
        let schedule = revalidationSchedule
        revalidationTask = Task { @MainActor [weak self] in
            do {
                try await operations.sleep(delay)
            } catch {
                guard let self else { return }
                handleRevalidationWaitFailure(schedule: schedule)
                return
            }
            guard !Task.isCancelled,
                  let self,
                  episodeActive,
                  retryEpisode == episode,
                  revalidationSchedule == schedule
            else { return }
            revalidationTask = nil
            nextRetryDelay = nil
            wakeSettlingArmed = false
            retryAttempt += 1
            if activeGeneration == 0 {
                state = .enumerating
            }
            if revalidate() {
                finishRevalidation()
                return
            }
            guard retryAttempt <= retryDelays.count else {
                episodeActive = false
                wakeSettlingArmed = false
                retryExhausted = true
                episodeReplacementState = .notRequested
                state = activeGeneration == 0 ? .exhausted : .running
                return
            }
            scheduleRevalidation(after: retryDelays[retryAttempt - 1])
        }
    }

    private func handleRevalidationWaitFailure(schedule: UInt64) {
        guard revalidationSchedule == schedule else { return }
        revalidationTask = nil
        nextRetryDelay = nil
        wakeSettlingArmed = false
        if !Task.isCancelled {
            episodeActive = false
            retryExhausted = true
            episodeReplacementState = .notRequested
            state = activeGeneration == 0 ? .exhausted : .running
        }
    }

    private func revalidate() -> Bool {
        guard let operations else { return false }
        if activeGeneration == 0, !devices.isEmpty {
            guard teardownRegistrations(resetGestureState: false) else { return false }
        }

        let enumeration = operations.enumerate()
        lastEnumeration = enumeration.outcome
        guard case .success = enumeration.outcome, !enumeration.devices.isEmpty else {
            invalidateActiveGeneration()
            _ = teardownRegistrations(resetGestureState: true)
            return false
        }

        let discoveredIds = Set(enumeration.devices.map(\.registryId))
        let registeredIds = devices.registryIds
        let forceReplacement = episodeReplacementState == .pending
        let awaitingTopologyChange = episodeReasons.contains(.arrival) || episodeReasons.contains(.removal)
        let topologyConverged = !awaitingTopologyChange || discoveredIds != episodeBaselineDeviceIds
        if activeGeneration != 0, discoveredIds == registeredIds, !forceReplacement {
            let allRunning = devices.allRunning()
            if allRunning {
                state = .running
                return topologyConverged
            }
        }

        invalidateActiveGeneration()
        guard teardownRegistrations(resetGestureState: true) else { return false }
        guard register(enumeration: enumeration) else { return false }
        return topologyConverged
    }

    private func finishRevalidation() {
        episodeActive = false
        retryAttempt = 0
        nextRetryDelay = nil
        retryExhausted = false
        wakeSettlingArmed = false
        episodeReplacementState = .notRequested
    }

    private func cancelRevalidation() {
        revalidationTask?.cancel()
        revalidationTask = nil
        revalidationSchedule &+= 1
        episodeActive = false
        episodeReasons.removeAll(keepingCapacity: true)
        episodeBaselineDeviceIds.removeAll(keepingCapacity: true)
        retryAttempt = 0
        nextRetryDelay = nil
        retryExhausted = false
        wakeSettlingArmed = false
        episodeReplacementState = .notRequested
    }
}

extension MultitouchGestureSource {
    func diagnosticsSnapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            state: state,
            activeGeneration: activeGeneration == 0 ? nil : activeGeneration,
            registeredDeviceCount: devices.registeredCount,
            lastEnumeration: lastEnumeration,
            lastRegister: devices.lastRegister,
            lastStart: devices.lastStart,
            lastRunningCheck: devices.lastRunningCheck,
            lastStop: devices.lastStop,
            lastUnregister: devices.lastUnregister,
            retryReasons: episodeReasons.sorted { $0.rawValue < $1.rawValue },
            retryEpisode: retryEpisode,
            retryAttempt: retryAttempt,
            maximumAttempts: retryDelays.count + 1,
            nextRetryDelay: nextRetryDelay,
            retryExhausted: retryExhausted,
            topologyObserverState: topologyMonitor.topologyObserverState,
            lastTopologySignal: lastTopologySignal,
            lastRawCallbackTimestamp: lastRawCallbackTimestamp,
            lastRawCallbackGeneration: lastRawCallbackGeneration,
            lastAcceptedCallbackTimestamp: lastAcceptedCallbackTimestamp,
            lastAcceptedCallbackGeneration: lastAcceptedCallbackGeneration
        )
    }

    nonisolated func beginPerformanceCapture() {
        rawFrameMailbox.beginPerformanceCapture()
    }

    func recordTraceSnapshot() {
        guard TrackpadScrollTrace.shared.isActive, activeGeneration != 0 else { return }
        devices.recordTraceSnapshot(generation: activeGeneration)
        rawFrameMailbox.recordTraceSnapshot(slotCount: devices.registeredCount)
    }

    nonisolated func performanceSnapshot() -> MultitouchFrameMailbox.PerformanceSnapshot? {
        rawFrameMailbox.performanceSnapshot()
    }

    nonisolated func endPerformanceCapture() -> MultitouchFrameMailbox.PerformanceSnapshot? {
        rawFrameMailbox.endPerformanceCapture()
    }

    func handleRawFrame(
        _ frame: RawFrame,
        generation: UInt,
        location: CGPoint,
        terminalPhase: NSEvent.Phase = .ended,
        contactSession: MultitouchContactSession? = nil
    ) {
        lastRawCallbackTimestamp = frame.timestamp
        lastRawCallbackGeneration = generation
        guard state == .running, generation != 0, generation == activeGeneration else { return }
        lastAcceptedCallbackTimestamp = frame.timestamp
        lastAcceptedCallbackGeneration = generation
        let result = Self.makeSnapshot(
            frame: frame,
            location: location,
            previousActiveCount: previousActiveCount,
            terminalPhase: terminalPhase,
            contactSession: contactSession
        )
        previousActiveCount = result.activeCount
        if let snapshot = result.snapshot {
            onSnapshot?(snapshot)
        }
    }

    private final class WeakSharedRoute: @unchecked Sendable {
        weak var source: MultitouchGestureSource?
    }

    private nonisolated static let sharedRoute = OSAllocatedUnfairLock(initialState: WeakSharedRoute())

    nonisolated static var shared: MultitouchGestureSource? {
        get { sharedRoute.withLock { $0.source } }
        set { sharedRoute.withLock { $0.source = newValue } }
    }

    private static let contactCallback: MultitouchBinding.ContactCallback = { _, fingers, count, timestamp, _, refcon in
        let token = RegistrationToken(bitPattern: refcon.map(UInt.init(bitPattern:)) ?? 0)
        let frame = MultitouchGestureSource.buildRawFrame(fingers: fingers, count: count, timestamp: timestamp)
        guard let source = MultitouchGestureSource.shared else { return 0 }
        source.enqueueRawFrame(frame, token: token)
        return 0
    }

    private nonisolated func enqueueRawFrame(_ frame: RawFrame, token: RegistrationToken) {
        guard rawFrameMailbox.offer(frame, generation: token.generation, slot: token.slot) else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.drainRawFrameMailbox()
            }
        }
    }

    func hasSender(_ senderId: UInt64) -> Bool {
        state == .running && devices.hasSender(senderId)
    }

    func drainRawFrameMailbox(location: CGPoint? = nil) {
        let batch = rawFrameMailbox.take()
        defer { rawFrameMailbox.recycle(batch.deliveries) }
        guard state == .running, activeGeneration != 0,
              batch.contacts.generation == activeGeneration
        else { return }
        if batch.contactsChanged {
            onContactSessions?(batch.contacts)
        }
        guard !batch.deliveries.isEmpty else { return }
        let cursorLocation: CGPoint
        if let location {
            cursorLocation = location
        } else {
            cursorLocation = NSEvent.mouseLocation
            rawFrameMailbox.recordCursorSample()
        }
        for delivery in batch.deliveries {
            guard delivery.generation == activeGeneration else { continue }
            let contactSession = MultitouchContactSession(
                generation: delivery.generation,
                slot: delivery.slot,
                session: delivery.contactSession,
                senderId: devices.senderId(at: delivery.slot)
            )
            handleRawFrame(
                delivery.frame,
                generation: delivery.generation,
                location: cursorLocation,
                terminalPhase: delivery.kind == .cancelled ? .cancelled : .ended,
                contactSession: contactSession
            )
        }
    }
}

extension MultitouchGestureSource {
    private static func allocateRegistrationGeneration() -> UInt {
        repeat {
            nextRegistrationGeneration &+= 1
        } while nextRegistrationGeneration == 0
        return nextRegistrationGeneration
    }

    private func register(enumeration: MultitouchBinding.Enumeration) -> Bool {
        let generation = Self.allocateRegistrationGeneration()
        guard devices.register(enumeration: enumeration, generation: generation) else { return false }
        activeGeneration = generation
        rawFrameMailbox.activate(generation: generation)
        if episodeReplacementState == .pending { episodeReplacementState = .completed }
        state = .running
        recordTraceSnapshot()
        return true
    }

    private func teardownRegistrations(resetGestureState: Bool) -> Bool {
        if resetGestureState, !devices.isEmpty || previousActiveCount > 0 {
            onSourceWillReplace?()
            previousActiveCount = 0
        }
        return devices.teardown()
    }

    private func invalidateActiveGeneration() {
        activeGeneration = 0
        rawFrameMailbox.invalidate()
    }
}
