// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Dispatch
import Foundation

enum AppAXFrameLane: Hashable, Sendable {
    case ordinary
    case park
    case closing
}

func skippedFrameApplyResult(
    for request: AppAXFrameWriteRequest,
    reason: AXFrameWriteFailureReason
) -> AXFrameApplyResult {
    AXFrameApplyResult(
        requestId: request.requestId,
        pid: request.pid,
        windowId: request.windowId,
        expectedWindow: request.expectedWindow,
        targetFrame: request.frame,
        currentFrameHint: request.currentFrameHint,
        writeResult: .skipped(
            targetFrame: request.frame,
            currentFrameHint: request.currentFrameHint,
            failureReason: reason,
            components: request.components
        ),
        traceRequestId: request.traceRequestId
    )
}

@MainActor
final class AppAXFrameMailbox {
    typealias Completion = @MainActor ([AXFrameApplyResult]) -> Void

    struct Item: Sendable {
        let submissionId: UInt64
        let index: Int
        let request: AppAXFrameWriteRequest
        let enqueuedAt: UInt64?
    }

    struct Drain: Sendable {
        let id: UInt64
        let items: [Item]
    }

    struct Delivery {
        let results: [AXFrameApplyResult]
        let completion: Completion

        @MainActor func deliver() {
            completion(results)
        }
    }

    struct Outcome {
        let drain: Drain?
        let deliveries: [Delivery]
    }

    private struct Submission {
        var results: [AXFrameApplyResult?]
        let completion: Completion
    }

    private var nextSubmissionId: UInt64 = 1
    private var nextDrainId: UInt64 = 1
    private var submissions: [UInt64: Submission] = [:]
    private var pendingByWindowId: [Int: Item] = [:]
    private var activeDrain: Drain?
    private var isStopped = false
    private let lane: AppAXFrameLane

    nonisolated init(lane: AppAXFrameLane = .ordinary) {
        self.lane = lane
    }

    var pendingCount: Int {
        pendingByWindowId.count
    }

    var inFlightCount: Int {
        activeDrain?.items.count ?? 0
    }

    func hasInFlightFrameWrite(for windowId: Int) -> Bool {
        activeDrain?.items.contains { $0.request.windowId == windowId } == true
    }

    var runtimeDepths: AppAXMailboxDepths {
        switch lane {
        case .ordinary:
            AppAXMailboxDepths(
                ordinaryPending: pendingCount,
                ordinaryInFlight: inFlightCount
            )
        case .park:
            AppAXMailboxDepths(
                parkPending: pendingCount,
                parkInFlight: inFlightCount
            )
        case .closing:
            AppAXMailboxDepths(
                closingPending: pendingCount,
                closingInFlight: inFlightCount
            )
        }
    }

    func enqueue(
        _ requests: [AppAXFrameWriteRequest],
        callbackGeneration: UInt64 = 0,
        completion: @escaping Completion
    ) -> Outcome {
        guard !requests.isEmpty else {
            return Outcome(drain: nil, deliveries: [Delivery(results: [], completion: completion)])
        }
        let frameTraceActive = FrameApplyTrace.shared.isActive
        AppAXContextRuntimeMetrics.shared.noteSubmitted(requests.count, lane: lane)
        guard !isStopped else {
            if frameTraceActive {
                for request in requests {
                    recordTerminalTrace(
                        request,
                        outcome: "mailbox/stopped/terminal",
                        callbackGeneration: callbackGeneration
                    )
                }
            }
            return stoppedOutcome(requests, completion: completion)
        }

        let previousPendingCount = pendingCount
        let previousInFlightCount = inFlightCount
        let deliveries = enqueuePendingRequests(
            requests,
            callbackGeneration: callbackGeneration,
            frameTraceActive: frameTraceActive,
            completion: completion
        )

        let drain = startDrainIfIdle()
        AppAXContextRuntimeMetrics.shared.noteDepthChange(
            lane: lane,
            pendingDelta: pendingCount - previousPendingCount,
            inFlightDelta: inFlightCount - previousInFlightCount
        )
        return Outcome(drain: drain, deliveries: deliveries)
    }

    private func enqueuePendingRequests(
        _ requests: [AppAXFrameWriteRequest],
        callbackGeneration: UInt64,
        frameTraceActive: Bool,
        completion: @escaping Completion
    ) -> [Delivery] {
        let submissionId = nextSubmissionId
        nextSubmissionId &+= 1
        submissions[submissionId] = Submission(
            results: Array(repeating: nil, count: requests.count),
            completion: completion
        )
        let capturesEnqueueTime = lane.supportsFrameEffectTracing
            && (AppAXContextRuntimeMetrics.shared.isActive || AXWriteLatencyTrace.shared.isActive)
        var deliveries: [Delivery] = []
        for (index, request) in requests.enumerated() {
            let enqueuedAt = capturesEnqueueTime
                ? DispatchTime.now().uptimeNanoseconds
                : nil
            if let superseded = pendingByWindowId.updateValue(
                Item(
                    submissionId: submissionId,
                    index: index,
                    request: request,
                    enqueuedAt: enqueuedAt
                ),
                forKey: request.windowId
            ) {
                AppAXContextRuntimeMetrics.shared.noteReplaced(lane: lane)
                if frameTraceActive {
                    recordTerminalTrace(
                        superseded.request,
                        outcome: "mailbox/superseded/terminal",
                        callbackGeneration: callbackGeneration,
                        relatedTraceId: request.traceRequestId,
                        submissionId: superseded.submissionId
                    )
                }
                resolve(
                    superseded,
                    result: skippedFrameApplyResult(for: superseded.request, reason: .cancelled),
                    deliveries: &deliveries
                )
            }
        }

        return deliveries
    }

    private func recordTerminalTrace(
        _ request: AppAXFrameWriteRequest,
        outcome: String,
        callbackGeneration: UInt64,
        relatedTraceId: UInt64 = 0,
        submissionId: UInt64 = 0
    ) {
        FrameApplyTrace.recordEvent(
            pid: request.pid,
            windowId: request.windowId,
            outcome: outcome,
            target: request.frame,
            requestId: request.requestId,
            traceRequestId: request.traceRequestId,
            relatedTraceId: relatedTraceId,
            callbackGeneration: callbackGeneration,
            lane: lane,
            submissionId: submissionId
        )
    }

    private func stoppedOutcome(
        _ requests: [AppAXFrameWriteRequest],
        completion: @escaping Completion
    ) -> Outcome {
        AppAXContextRuntimeMetrics.shared.noteCancelledCompletions(
            requests.count,
            lane: lane
        )
        return Outcome(
            drain: nil,
            deliveries: [
                Delivery(
                    results: requests.map {
                        skippedFrameApplyResult(for: $0, reason: .cancelled)
                    },
                    completion: completion
                )
            ]
        )
    }

    func finish(drainId: UInt64, results: [AXFrameApplyResult]) -> Outcome {
        guard let drain = activeDrain, drain.id == drainId else {
            return Outcome(drain: nil, deliveries: [])
        }
        let previousPendingCount = pendingCount
        let previousInFlightCount = inFlightCount
        activeDrain = nil
        var deliveries: [Delivery] = []
        for (index, item) in drain.items.enumerated() {
            let result = index < results.count
                ? results[index]
                : skippedFrameApplyResult(for: item.request, reason: .cancelled)
            resolve(item, result: result, deliveries: &deliveries)
        }
        let nextDrain = startDrainIfIdle()
        AppAXContextRuntimeMetrics.shared.noteDepthChange(
            lane: lane,
            pendingDelta: pendingCount - previousPendingCount,
            inFlightDelta: inFlightCount - previousInFlightCount
        )
        return Outcome(drain: nextDrain, deliveries: deliveries)
    }

    func cancelAll() -> [Delivery] {
        let previousPendingCount = pendingCount
        let previousInFlightCount = inFlightCount
        var deliveries: [Delivery] = []
        if let activeDrain {
            for item in activeDrain.items {
                resolve(
                    item,
                    result: skippedFrameApplyResult(for: item.request, reason: .cancelled),
                    deliveries: &deliveries
                )
            }
        }
        for item in pendingByWindowId.values {
            resolve(
                item,
                result: skippedFrameApplyResult(for: item.request, reason: .cancelled),
                deliveries: &deliveries
            )
        }
        activeDrain = nil
        pendingByWindowId.removeAll(keepingCapacity: false)
        submissions.removeAll(keepingCapacity: false)
        AppAXContextRuntimeMetrics.shared.noteDepthChange(
            lane: lane,
            pendingDelta: -previousPendingCount,
            inFlightDelta: -previousInFlightCount
        )
        return deliveries
    }

    func beginShutdown() -> [Delivery] {
        isStopped = true
        return cancelAll()
    }

    private func startDrainIfIdle() -> Drain? {
        guard !isStopped, activeDrain == nil, !pendingByWindowId.isEmpty else { return nil }
        let drain = Drain(id: nextDrainId, items: Array(pendingByWindowId.values))
        nextDrainId &+= 1
        pendingByWindowId.removeAll(keepingCapacity: true)
        activeDrain = drain
        return drain
    }

    private func resolve(
        _ item: Item,
        result: AXFrameApplyResult,
        deliveries: inout [Delivery]
    ) {
        guard var submission = submissions[item.submissionId],
              submission.results.indices.contains(item.index),
              submission.results[item.index] == nil
        else {
            return
        }
        submission.results[item.index] = result
        AppAXContextRuntimeMetrics.shared.noteCompleted(
            lane: lane,
            cancelled: result.writeResult.failureReason == .cancelled
        )
        if submission.results.allSatisfy({ $0 != nil }) {
            submissions.removeValue(forKey: item.submissionId)
            deliveries.append(
                Delivery(
                    results: submission.results.compactMap { $0 },
                    completion: submission.completion
                )
            )
        } else {
            submissions[item.submissionId] = submission
        }
    }
}

@MainActor
final class AppAXClosingFrameMailbox {
    struct Drain: Sendable {
        let id: UInt64
        let requests: [AppAXClosingFrameWriteRequest]
    }

    private var nextDrainId: UInt64 = 1
    private var pendingByAnimationId: [UUID: AppAXClosingFrameWriteRequest] = [:]
    private var activeDrainId: UInt64?
    private var activeDrainCount = 0

    var pendingCount: Int {
        pendingByAnimationId.count
    }

    var inFlightCount: Int {
        activeDrainCount
    }

    var runtimeDepths: AppAXMailboxDepths {
        AppAXMailboxDepths(
            closingPending: pendingCount,
            closingInFlight: inFlightCount
        )
    }

    func enqueue(_ requests: [AppAXClosingFrameWriteRequest]) -> Drain? {
        let previousPendingCount = pendingCount
        let previousInFlightCount = inFlightCount
        AppAXContextRuntimeMetrics.shared.noteSubmitted(requests.count, lane: .closing)
        for request in requests {
            let wasReplaced = pendingByAnimationId.updateValue(
                request,
                forKey: request.target.animationId
            ) != nil
            guard wasReplaced else { continue }
            AppAXContextRuntimeMetrics.shared.noteReplaced(lane: .closing)
            AppAXContextRuntimeMetrics.shared.noteCompleted(lane: .closing, cancelled: true)
        }
        let drain = startDrainIfIdle()
        AppAXContextRuntimeMetrics.shared.noteDepthChange(
            lane: .closing,
            pendingDelta: pendingCount - previousPendingCount,
            inFlightDelta: inFlightCount - previousInFlightCount
        )
        return drain
    }

    func finish(drainId: UInt64, cancelledCount: Int) -> Drain? {
        guard activeDrainId == drainId else { return nil }
        let previousPendingCount = pendingCount
        let previousInFlightCount = inFlightCount
        for index in 0 ..< activeDrainCount {
            AppAXContextRuntimeMetrics.shared.noteCompleted(
                lane: .closing,
                cancelled: index < cancelledCount
            )
        }
        activeDrainId = nil
        activeDrainCount = 0
        let drain = startDrainIfIdle()
        AppAXContextRuntimeMetrics.shared.noteDepthChange(
            lane: .closing,
            pendingDelta: pendingCount - previousPendingCount,
            inFlightDelta: inFlightCount - previousInFlightCount
        )
        return drain
    }

    func cancelAll() {
        let previousPendingCount = pendingCount
        let previousInFlightCount = inFlightCount
        for _ in 0 ..< activeDrainCount {
            AppAXContextRuntimeMetrics.shared.noteCompleted(lane: .closing, cancelled: true)
        }
        for _ in pendingByAnimationId.values {
            AppAXContextRuntimeMetrics.shared.noteCompleted(lane: .closing, cancelled: true)
        }
        activeDrainId = nil
        activeDrainCount = 0
        pendingByAnimationId.removeAll(keepingCapacity: false)
        AppAXContextRuntimeMetrics.shared.noteDepthChange(
            lane: .closing,
            pendingDelta: -previousPendingCount,
            inFlightDelta: -previousInFlightCount
        )
    }

    private func startDrainIfIdle() -> Drain? {
        guard activeDrainId == nil, !pendingByAnimationId.isEmpty else { return nil }
        let drain = Drain(id: nextDrainId, requests: Array(pendingByAnimationId.values))
        nextDrainId &+= 1
        pendingByAnimationId.removeAll(keepingCapacity: true)
        activeDrainId = drain.id
        activeDrainCount = drain.requests.count
        return drain
    }
}
