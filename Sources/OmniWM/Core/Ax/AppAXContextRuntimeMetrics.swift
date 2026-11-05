// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Dispatch
import Foundation
import os
import Synchronization

struct AppAXMailboxDepths: Equatable, Sendable {
    var ordinaryPending = 0
    var ordinaryInFlight = 0
    var parkPending = 0
    var parkInFlight = 0
    var closingPending = 0
    var closingInFlight = 0

    var pending: Int {
        ordinaryPending + parkPending + closingPending
    }

    var inFlight: Int {
        ordinaryInFlight + parkInFlight + closingInFlight
    }

    mutating func add(_ other: AppAXMailboxDepths) {
        ordinaryPending += other.ordinaryPending
        ordinaryInFlight += other.ordinaryInFlight
        parkPending += other.parkPending
        parkInFlight += other.parkInFlight
        closingPending += other.closingPending
        closingInFlight += other.closingInFlight
    }
}

struct AppAXContextRuntimeSnapshot: Equatable, Sendable {
    var ordinarySubmitted: UInt64 = 0
    var ordinaryStarted: UInt64 = 0
    var ordinaryCompleted: UInt64 = 0
    var ordinaryCancelled: UInt64 = 0
    var ordinaryReplaced: UInt64 = 0
    var parkSubmitted: UInt64 = 0
    var parkStarted: UInt64 = 0
    var parkCompleted: UInt64 = 0
    var parkCancelled: UInt64 = 0
    var parkReplaced: UInt64 = 0
    var closingSubmitted: UInt64 = 0
    var closingStarted: UInt64 = 0
    var closingCompleted: UInt64 = 0
    var closingCancelled: UInt64 = 0
    var closingReplaced: UInt64 = 0
    var queueWaitSamples: UInt64 = 0
    var queueWaitUnder1ms: UInt64 = 0
    var queueWaitUnder4ms: UInt64 = 0
    var queueWaitUnder16ms: UInt64 = 0
    var queueWaitAtLeast16ms: UInt64 = 0
    var ordinaryPending = 0
    var ordinaryInFlight = 0
    var parkPending = 0
    var parkInFlight = 0
    var closingPending = 0
    var closingInFlight = 0
    var pendingHighWater = 0
    var inFlightHighWater = 0
    var ordinaryPendingHighWater = 0
    var ordinaryInFlightHighWater = 0
    var parkPendingHighWater = 0
    var parkInFlightHighWater = 0
    var closingPendingHighWater = 0
    var closingInFlightHighWater = 0
    var staleBeforeIPC: UInt64 = 0
    var enhancedUICalls: UInt64 = 0

    var submitted: UInt64 {
        ordinarySubmitted + parkSubmitted + closingSubmitted
    }

    var started: UInt64 {
        ordinaryStarted + parkStarted + closingStarted
    }

    var completed: UInt64 {
        ordinaryCompleted + parkCompleted + closingCompleted
    }

    var cancelled: UInt64 {
        ordinaryCancelled + parkCancelled + closingCancelled
    }

    var replaced: UInt64 {
        ordinaryReplaced + parkReplaced + closingReplaced
    }

    var pending: Int {
        ordinaryPending + parkPending + closingPending
    }

    var inFlight: Int {
        ordinaryInFlight + parkInFlight + closingInFlight
    }

    mutating func seedDepths(_ depths: AppAXMailboxDepths) {
        ordinaryPending = depths.ordinaryPending
        ordinaryInFlight = depths.ordinaryInFlight
        parkPending = depths.parkPending
        parkInFlight = depths.parkInFlight
        closingPending = depths.closingPending
        closingInFlight = depths.closingInFlight
        updateDepthHighWater()
    }

    mutating func updateDepthHighWater() {
        ordinaryPendingHighWater = max(ordinaryPendingHighWater, ordinaryPending)
        ordinaryInFlightHighWater = max(ordinaryInFlightHighWater, ordinaryInFlight)
        parkPendingHighWater = max(parkPendingHighWater, parkPending)
        parkInFlightHighWater = max(parkInFlightHighWater, parkInFlight)
        closingPendingHighWater = max(closingPendingHighWater, closingPending)
        closingInFlightHighWater = max(closingInFlightHighWater, closingInFlight)
        pendingHighWater = max(pendingHighWater, pending)
        inFlightHighWater = max(inFlightHighWater, inFlight)
    }
}

final class AppAXContextRuntimeMetrics: @unchecked Sendable {
    static let shared = AppAXContextRuntimeMetrics()

    private let activeGeneration = Atomic<UInt64>(0)
    private let nextGeneration = Atomic<UInt64>(0)
    private let activeWriters = Atomic<UInt64>(0)
    private let ordinarySubmitted = Atomic<UInt64>(0)
    private let ordinaryStarted = Atomic<UInt64>(0)
    private let ordinaryCompleted = Atomic<UInt64>(0)
    private let ordinaryCancelled = Atomic<UInt64>(0)
    private let ordinaryReplaced = Atomic<UInt64>(0)
    private let parkSubmitted = Atomic<UInt64>(0)
    private let parkStarted = Atomic<UInt64>(0)
    private let parkCompleted = Atomic<UInt64>(0)
    private let parkCancelled = Atomic<UInt64>(0)
    private let parkReplaced = Atomic<UInt64>(0)
    private let closingSubmitted = Atomic<UInt64>(0)
    private let closingStarted = Atomic<UInt64>(0)
    private let closingCompleted = Atomic<UInt64>(0)
    private let closingCancelled = Atomic<UInt64>(0)
    private let closingReplaced = Atomic<UInt64>(0)
    private let queueWaitSamples = Atomic<UInt64>(0)
    private let queueWaitUnder1ms = Atomic<UInt64>(0)
    private let queueWaitUnder4ms = Atomic<UInt64>(0)
    private let queueWaitUnder16ms = Atomic<UInt64>(0)
    private let queueWaitAtLeast16ms = Atomic<UInt64>(0)
    private let staleBeforeIPC = Atomic<UInt64>(0)
    private let enhancedUICalls = Atomic<UInt64>(0)
    private let gauges = OSAllocatedUnfairLock(initialState: AppAXContextRuntimeSnapshot())

    var isActive: Bool {
        activeGeneration.load(ordering: .relaxed) != 0
    }

    @discardableResult
    func beginCapture(initialDepths: AppAXMailboxDepths = AppAXMailboxDepths())
        -> AppAXContextRuntimeSnapshot
    {
        deactivateAndWait()
        resetScalarCounters()
        gauges.withLock { state in
            state = AppAXContextRuntimeSnapshot()
            state.seedDepths(initialDepths)
        }
        let snapshot = snapshot()
        var generation = nextGeneration.wrappingAdd(1, ordering: .relaxed).newValue
        if generation == 0 {
            generation = nextGeneration.wrappingAdd(1, ordering: .relaxed).newValue
        }
        activeGeneration.store(generation, ordering: .releasing)
        return snapshot
    }

    func endCapture() {
        deactivateAndWait()
    }

    func snapshot() -> AppAXContextRuntimeSnapshot {
        let gaugeSnapshot = gauges.withLock { $0 }
        return AppAXContextRuntimeSnapshot(
            ordinarySubmitted: ordinarySubmitted.load(ordering: .relaxed),
            ordinaryStarted: ordinaryStarted.load(ordering: .relaxed),
            ordinaryCompleted: ordinaryCompleted.load(ordering: .relaxed),
            ordinaryCancelled: ordinaryCancelled.load(ordering: .relaxed),
            ordinaryReplaced: ordinaryReplaced.load(ordering: .relaxed),
            parkSubmitted: parkSubmitted.load(ordering: .relaxed),
            parkStarted: parkStarted.load(ordering: .relaxed),
            parkCompleted: parkCompleted.load(ordering: .relaxed),
            parkCancelled: parkCancelled.load(ordering: .relaxed),
            parkReplaced: parkReplaced.load(ordering: .relaxed),
            closingSubmitted: closingSubmitted.load(ordering: .relaxed),
            closingStarted: closingStarted.load(ordering: .relaxed),
            closingCompleted: closingCompleted.load(ordering: .relaxed),
            closingCancelled: closingCancelled.load(ordering: .relaxed),
            closingReplaced: closingReplaced.load(ordering: .relaxed),
            queueWaitSamples: queueWaitSamples.load(ordering: .relaxed),
            queueWaitUnder1ms: queueWaitUnder1ms.load(ordering: .relaxed),
            queueWaitUnder4ms: queueWaitUnder4ms.load(ordering: .relaxed),
            queueWaitUnder16ms: queueWaitUnder16ms.load(ordering: .relaxed),
            queueWaitAtLeast16ms: queueWaitAtLeast16ms.load(ordering: .relaxed),
            ordinaryPending: gaugeSnapshot.ordinaryPending,
            ordinaryInFlight: gaugeSnapshot.ordinaryInFlight,
            parkPending: gaugeSnapshot.parkPending,
            parkInFlight: gaugeSnapshot.parkInFlight,
            closingPending: gaugeSnapshot.closingPending,
            closingInFlight: gaugeSnapshot.closingInFlight,
            pendingHighWater: gaugeSnapshot.pendingHighWater,
            inFlightHighWater: gaugeSnapshot.inFlightHighWater,
            ordinaryPendingHighWater: gaugeSnapshot.ordinaryPendingHighWater,
            ordinaryInFlightHighWater: gaugeSnapshot.ordinaryInFlightHighWater,
            parkPendingHighWater: gaugeSnapshot.parkPendingHighWater,
            parkInFlightHighWater: gaugeSnapshot.parkInFlightHighWater,
            closingPendingHighWater: gaugeSnapshot.closingPendingHighWater,
            closingInFlightHighWater: gaugeSnapshot.closingInFlightHighWater,
            staleBeforeIPC: staleBeforeIPC.load(ordering: .relaxed),
            enhancedUICalls: enhancedUICalls.load(ordering: .relaxed)
        )
    }

    func noteSubmitted(_ count: Int, lane: AppAXFrameLane) {
        withActiveCapture {
            switch lane {
            case .ordinary:
                _ = ordinarySubmitted.wrappingAdd(UInt64(count), ordering: .relaxed)
            case .park:
                _ = parkSubmitted.wrappingAdd(UInt64(count), ordering: .relaxed)
            case .closing:
                _ = closingSubmitted.wrappingAdd(UInt64(count), ordering: .relaxed)
            }
        }
    }

    func noteOrdinaryStarted(_ items: [AppAXFrameMailbox.Item]) {
        noteStarted(items, lane: .ordinary)
    }

    func noteParkStarted(_ items: [AppAXFrameMailbox.Item]) {
        noteStarted(items, lane: .park)
    }

    private func noteStarted(_ items: [AppAXFrameMailbox.Item], lane: AppAXFrameLane) {
        withActiveCapture {
            recordStarted(items, lane: lane)
        }
    }

    func recordStarted(_ items: [AppAXFrameMailbox.Item], lane: AppAXFrameLane) {
        let now = DispatchTime.now().uptimeNanoseconds
        switch lane {
        case .ordinary:
            _ = ordinaryStarted.wrappingAdd(UInt64(items.count), ordering: .relaxed)
        case .park:
            _ = parkStarted.wrappingAdd(UInt64(items.count), ordering: .relaxed)
        case .closing:
            _ = closingStarted.wrappingAdd(UInt64(items.count), ordering: .relaxed)
        }
        var samples: UInt64 = 0
        var under1ms: UInt64 = 0
        var under4ms: UInt64 = 0
        var under16ms: UInt64 = 0
        var atLeast16ms: UInt64 = 0
        for item in items {
            guard let enqueuedAt = item.enqueuedAt else { continue }
            samples &+= 1
            let wait = now >= enqueuedAt ? now - enqueuedAt : 0
            if wait < 1_000_000 {
                under1ms &+= 1
            } else if wait < 4_000_000 {
                under4ms &+= 1
            } else if wait < 16_000_000 {
                under16ms &+= 1
            } else {
                atLeast16ms &+= 1
            }
        }
        _ = queueWaitSamples.wrappingAdd(samples, ordering: .relaxed)
        _ = queueWaitUnder1ms.wrappingAdd(under1ms, ordering: .relaxed)
        _ = queueWaitUnder4ms.wrappingAdd(under4ms, ordering: .relaxed)
        _ = queueWaitUnder16ms.wrappingAdd(under16ms, ordering: .relaxed)
        _ = queueWaitAtLeast16ms.wrappingAdd(atLeast16ms, ordering: .relaxed)
    }

    func noteClosingStarted(_ count: Int) {
        withActiveCapture {
            _ = closingStarted.wrappingAdd(UInt64(count), ordering: .relaxed)
        }
    }

    func noteCompleted(lane: AppAXFrameLane, cancelled: Bool) {
        withActiveCapture {
            switch lane {
            case .ordinary:
                _ = ordinaryCompleted.wrappingAdd(1, ordering: .relaxed)
                if cancelled {
                    _ = ordinaryCancelled.wrappingAdd(1, ordering: .relaxed)
                }
            case .park:
                _ = parkCompleted.wrappingAdd(1, ordering: .relaxed)
                if cancelled {
                    _ = parkCancelled.wrappingAdd(1, ordering: .relaxed)
                }
            case .closing:
                _ = closingCompleted.wrappingAdd(1, ordering: .relaxed)
                if cancelled {
                    _ = closingCancelled.wrappingAdd(1, ordering: .relaxed)
                }
            }
        }
    }

    func noteCancelledCompletions(_ count: Int, lane: AppAXFrameLane) {
        withActiveCapture {
            switch lane {
            case .ordinary:
                _ = ordinaryCompleted.wrappingAdd(UInt64(count), ordering: .relaxed)
                _ = ordinaryCancelled.wrappingAdd(UInt64(count), ordering: .relaxed)
            case .park:
                _ = parkCompleted.wrappingAdd(UInt64(count), ordering: .relaxed)
                _ = parkCancelled.wrappingAdd(UInt64(count), ordering: .relaxed)
            case .closing:
                _ = closingCompleted.wrappingAdd(UInt64(count), ordering: .relaxed)
                _ = closingCancelled.wrappingAdd(UInt64(count), ordering: .relaxed)
            }
        }
    }

    func noteReplaced(lane: AppAXFrameLane) {
        withActiveCapture {
            switch lane {
            case .ordinary:
                _ = ordinaryReplaced.wrappingAdd(1, ordering: .relaxed)
            case .park:
                _ = parkReplaced.wrappingAdd(1, ordering: .relaxed)
            case .closing:
                _ = closingReplaced.wrappingAdd(1, ordering: .relaxed)
            }
        }
    }

    func noteDepthChange(
        lane: AppAXFrameLane,
        pendingDelta: Int,
        inFlightDelta: Int
    ) {
        guard pendingDelta != 0 || inFlightDelta != 0 else { return }
        withActiveCapture {
            gauges.withLock { snapshot in
                switch lane {
                case .ordinary:
                    snapshot.ordinaryPending = max(0, snapshot.ordinaryPending + pendingDelta)
                    snapshot.ordinaryInFlight = max(0, snapshot.ordinaryInFlight + inFlightDelta)
                case .park:
                    snapshot.parkPending = max(0, snapshot.parkPending + pendingDelta)
                    snapshot.parkInFlight = max(0, snapshot.parkInFlight + inFlightDelta)
                case .closing:
                    snapshot.closingPending = max(0, snapshot.closingPending + pendingDelta)
                    snapshot.closingInFlight = max(0, snapshot.closingInFlight + inFlightDelta)
                }
                snapshot.updateDepthHighWater()
            }
        }
    }

    func noteStaleBeforeIPC(_ count: Int) {
        withActiveCapture {
            _ = staleBeforeIPC.wrappingAdd(UInt64(count), ordering: .relaxed)
        }
    }

    func noteEnhancedUICalls(_ count: Int) {
        withActiveCapture {
            _ = enhancedUICalls.wrappingAdd(UInt64(count), ordering: .relaxed)
        }
    }

    @inline(__always)
    func withActiveCapture(_ operation: () -> Void) {
        let generation = activeGeneration.load(ordering: .relaxed)
        guard generation != 0 else { return }
        _ = activeWriters.wrappingAdd(1, ordering: .acquiringAndReleasing)
        defer {
            _ = activeWriters.wrappingSubtract(1, ordering: .acquiringAndReleasing)
        }
        guard activeGeneration.load(ordering: .acquiring) == generation else { return }
        operation()
    }

    private func deactivateAndWait() {
        activeGeneration.store(0, ordering: .releasing)
        while activeWriters.load(ordering: .acquiring) != 0 {
            sched_yield()
        }
    }

    private func resetScalarCounters() {
        ordinarySubmitted.store(0, ordering: .relaxed)
        ordinaryStarted.store(0, ordering: .relaxed)
        ordinaryCompleted.store(0, ordering: .relaxed)
        ordinaryCancelled.store(0, ordering: .relaxed)
        ordinaryReplaced.store(0, ordering: .relaxed)
        parkSubmitted.store(0, ordering: .relaxed)
        parkStarted.store(0, ordering: .relaxed)
        parkCompleted.store(0, ordering: .relaxed)
        parkCancelled.store(0, ordering: .relaxed)
        parkReplaced.store(0, ordering: .relaxed)
        closingSubmitted.store(0, ordering: .relaxed)
        closingStarted.store(0, ordering: .relaxed)
        closingCompleted.store(0, ordering: .relaxed)
        closingCancelled.store(0, ordering: .relaxed)
        closingReplaced.store(0, ordering: .relaxed)
        queueWaitSamples.store(0, ordering: .relaxed)
        queueWaitUnder1ms.store(0, ordering: .relaxed)
        queueWaitUnder4ms.store(0, ordering: .relaxed)
        queueWaitUnder16ms.store(0, ordering: .relaxed)
        queueWaitAtLeast16ms.store(0, ordering: .relaxed)
        staleBeforeIPC.store(0, ordering: .relaxed)
        enhancedUICalls.store(0, ordering: .relaxed)
    }
}
