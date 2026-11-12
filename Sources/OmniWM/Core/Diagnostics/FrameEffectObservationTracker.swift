// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Dispatch
import Foundation
import os

final class FrameEffectObservationTracker: @unchecked Sendable {
    static let shared = FrameEffectObservationTracker()

    private let state: OSAllocatedUnfairLock<FrameObservationState>
    @MainActor private var timeoutTask: Task<Void, Never>?

    init(
        capacity: Int = 512,
        timeoutNs: UInt64 = 1_000_000_000,
        maxMismatchCount: UInt8 = 3
    ) {
        state = OSAllocatedUnfairLock(initialState: FrameObservationState(
            capacity: capacity,
            timeoutNs: timeoutNs,
            maxMismatchCount: maxMismatchCount
        ))
    }

    var pendingCount: Int {
        state.withLock { $0.pendingCount }
    }

    var retainedStorageCapacity: Int {
        state.withLock { $0.retainedStorageCapacity }
    }

    @MainActor
    func beginCapture(generation: UInt64, startTimeoutTask: Bool = true) {
        timeoutTask?.cancel()
        timeoutTask = nil
        state.withLock { $0.beginCapture(generation: generation) }
        guard startTimeoutTask else { return }
        timeoutTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.expire(nowNs: DispatchTime.now().uptimeNanoseconds)
            }
        }
    }

    @MainActor
    func endCapture() {
        timeoutTask?.cancel()
        timeoutTask = nil
        let pending = state.withLock { $0.endCapture() }
        for item in pending {
            record(item, outcome: "server-observation/end-capture", terminal: true)
        }
    }

    func register(
        _ request: AppAXFrameWriteRequest,
        pid: pid_t,
        lane: AppAXFrameLane,
        attempt: UInt8,
        startedNs: UInt64
    ) {
        let traceRequestId = request.traceRequestId
        guard traceRequestId != 0, lane.supportsFrameEffectTracing else { return }
        let (superseded, capacityEviction) = state.withLock { $0.register(
            request,
            pid: pid,
            lane: lane,
            attempt: attempt,
            startedNs: startedNs
        ) }
        if let superseded {
            record(
                superseded,
                outcome: "server-observation/superseded",
                terminal: true,
                relatedTraceId: traceRequestId
            )
        }
        if let capacityEviction {
            record(capacityEviction, outcome: "server-observation/capacity", terminal: true)
        }
    }

    @discardableResult
    func noteFrameChanged(windowId: Int, eventNs: UInt64) -> UInt64? {
        state.withLock { $0.noteFrameChanged(windowId: windowId, eventNs: eventNs) }
    }

    func prepareObservation(windowId: Int, token: UInt64) -> FrameObservationSchedule.Work {
        state.withLock { $0.prepareObservation(windowId: windowId, token: token) }
    }

    func completeObservation(
        windowId: Int,
        token: UInt64,
        observed: CGRect?,
        sampledNs: UInt64
    ) -> UInt64? {
        let completion = state.withLock { $0.completeObservation(
            windowId: windowId,
            token: token,
            observed: observed,
            sampledNs: sampledNs
        ) }
        if let pending = completion.pending, let outcome = completion.outcome {
            record(pending, outcome: outcome, terminal: completion.terminal)
        }
        return completion.rescheduleToken
    }

    func noteWriteResult(_ result: AXFrameApplyResult) {
        guard result.traceRequestId != 0 else { return }
        let writeResult = result.writeResult
        guard writeResult.sizeError != .success
            || writeResult.positionError != .success
            || writeResult.failureReason == .valueCreationFailed
            || writeResult.failureReason == .contextUnavailable
            || writeResult.failureReason == .cancelled
            || writeResult.failureReason == .suppressed
        else {
            return
        }
        remove(
            traceRequestId: result.traceRequestId,
            outcome: "server-observation/write-terminal"
        )
    }

    func updateAcceptedTarget(traceRequestId: UInt64, target: CGRect) {
        guard traceRequestId != 0 else { return }
        let matched = state.withLock { $0.updateAcceptedTarget(traceRequestId: traceRequestId, target: target) }
        if let matched {
            record(matched, outcome: "server-observation/match-converged", terminal: true)
        }
    }

    func expire(nowNs: UInt64) {
        let expired = state.withLock { $0.expire(nowNs: nowNs) }
        for pending in expired {
            record(pending, outcome: "server-observation/timeout", terminal: true, uptimeNs: nowNs)
        }
    }

    static func noteCGSFrameChanged(windowId: Int, eventNs: UInt64) {
        guard let token = shared.noteFrameChanged(windowId: windowId, eventNs: eventNs) else { return }
        scheduleObservation(windowId: windowId, token: token)
    }

    @MainActor private static var queuedObservations: [(windowId: Int, token: UInt64)] = []
    @MainActor private static var observationPassScheduled = false

    @MainActor
    private static func observeWindowServerFrames(_ queued: [(windowId: Int, token: UInt64)]) {
        var sampled: [(windowId: Int, token: UInt64)] = []
        for (windowId, token) in queued {
            switch shared.prepareObservation(windowId: windowId, token: token) {
            case .none:
                continue
            case let .reschedule(nextToken):
                scheduleObservation(windowId: windowId, token: nextToken)
            case .sample:
                sampled.append((windowId, token))
            }
        }
        guard !sampled.isEmpty else { return }
        let bounds = SkyLight.shared.getWindowBounds(sampled.map { UInt32($0.windowId) })
        let sampledNs = DispatchTime.now().uptimeNanoseconds
        for (windowId, token) in sampled {
            let nextToken = shared.completeObservation(
                windowId: windowId,
                token: token,
                observed: bounds[UInt32(windowId)].map { ScreenCoordinateSpace.toAppKit(rect: $0) },
                sampledNs: sampledNs
            )
            if let nextToken {
                scheduleObservation(windowId: windowId, token: nextToken)
            }
        }
    }

    private static func scheduleObservation(windowId: Int, token: UInt64) {
        Task { @MainActor in
            queuedObservations.append((windowId, token))
            guard !observationPassScheduled else { return }
            observationPassScheduled = true
            await Task.yield()
            observationPassScheduled = false
            let queued = queuedObservations
            queuedObservations = []
            observeWindowServerFrames(queued)
        }
    }

    private func remove(traceRequestId: UInt64, outcome: String) {
        let removed = state.withLock { $0.remove(traceRequestId: traceRequestId) }
        if let removed {
            record(removed, outcome: outcome, terminal: true)
        }
    }

    private func record(
        _ pending: FrameObservationState.Pending,
        outcome: String,
        terminal: Bool,
        relatedTraceId: UInt64 = 0,
        uptimeNs: UInt64 = 0
    ) {
        FrameApplyTrace.recordEvent(
            pid: pending.pid,
            windowId: pending.windowId,
            outcome: terminal ? outcome + "/terminal" : outcome,
            target: pending.target,
            observed: pending.lastObserved,
            requestId: pending.requestId,
            traceRequestId: pending.traceRequestId,
            relatedTraceId: relatedTraceId,
            lane: pending.lane,
            attempt: pending.attempt,
            eventUptimeNs: pending.lastEventNs,
            uptimeNs: uptimeNs == 0 ? pending.lastSampleNs : uptimeNs
        )
    }
}
