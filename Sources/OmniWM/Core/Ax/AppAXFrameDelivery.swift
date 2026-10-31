// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

@MainActor
final class AppAXFrameDelivery {
    private var activeFrameBatchJobs: [UUID: RunLoopJob] = [:]
    private var activeParkFrameBatchJob: RunLoopJob?
    private var activeClosingFrameBatchJobs: [UUID: RunLoopJob] = [:]
    private let frameMailbox = AppAXFrameMailbox()
    private let parkFrameMailbox = AppAXFrameMailbox(lane: .park)
    private let closingFrameMailbox = AppAXClosingFrameMailbox()
    private let frameWriteGenerations = LockedWindowGenerationMap()
    private let parkFrameWriteGenerations = LockedWindowGenerationMap()
    private let closingFrameWriteGenerations = LockedClosingFrameGenerationMap()
    private let frameWriteSuppression = LockedWindowIdSet()

    nonisolated init() {}

    var runtimeMailboxDepths: AppAXMailboxDepths {
        var depths = frameMailbox.runtimeDepths
        depths.add(parkFrameMailbox.runtimeDepths)
        depths.add(closingFrameMailbox.runtimeDepths)
        return depths
    }

    var retryRaiseSuppression: LockedWindowIdSet {
        frameWriteSuppression
    }

    func hasInFlightFrameWrite(for windowId: Int) -> Bool {
        frameMailbox.hasInFlightFrameWrite(for: windowId)
    }

    func cancelFrameJob(for windowId: Int) {
        _ = frameWriteGenerations.nextGeneration(for: windowId)
    }

    func cancelParkFrameJob(for windowId: Int) {
        _ = parkFrameWriteGenerations.nextGeneration(for: windowId)
    }

    func suppressFrameWrite(for windowId: Int) {
        frameWriteSuppression.insert(windowId)
    }

    func unsuppressFrameWrite(for windowId: Int) {
        frameWriteSuppression.remove(windowId)
    }

    func setHardSuppressed(_ hidden: Bool) {
        frameWriteSuppression.setHardSuppressed(hidden)
    }

    func setWindowNativeSuppressed(_ suppressed: Bool, for windowId: Int) {
        cancelFrameJob(for: windowId)
        cancelParkFrameJob(for: windowId)
        closingFrameWriteGenerations.invalidate(for: windowId)
        frameWriteSuppression.setHardSuppressed(suppressed, for: windowId)
    }

    func invalidateClosingFrames() {
        closingFrameWriteGenerations.invalidateAll()
    }

    func prepareWindowRebind(from oldWindowId: Int, to newWindowId: Int) {
        frameWriteGenerations.invalidateAndMoveValue(from: oldWindowId, to: newWindowId)
        parkFrameWriteGenerations.invalidateAndMoveValue(from: oldWindowId, to: newWindowId)
        frameWriteSuppression.moveIfPresent(from: oldWindowId, to: newWindowId)
    }

    func prepareWindowRemoval(for windowId: Int) {
        frameWriteGenerations.invalidateAndRemove(windowId)
        parkFrameWriteGenerations.invalidateAndRemove(windowId)
        frameWriteSuppression.remove(windowId)
        frameWriteSuppression.setHardSuppressed(false, for: windowId)
    }

    func retainFrameState(only windowIds: Set<Int>) {
        frameWriteGenerations.retainOnly(windowIds)
        parkFrameWriteGenerations.retainOnly(windowIds)
        frameWriteSuppression.retainOnly(windowIds)
    }

    func enqueueClosingFrames(_ frames: [AXClosingFrameTarget]) -> AppAXClosingFrameMailbox.Drain? {
        let requests = frames.map {
            AppAXClosingFrameWriteRequest(
                target: $0,
                generation: closingFrameWriteGenerations.nextGeneration(for: $0.animationId, windowId: $0.windowId)
            )
        }
        return closingFrameMailbox.enqueue(requests)
    }

    func enqueueFrames(
        _ frames: [AXFrameApplicationRequest],
        callbackGeneration: UInt64,
        completion: @escaping AppAXFrameMailbox.Completion
    ) -> AppAXFrameMailbox.Outcome {
        frameMailbox.enqueue(
            makeFrameWriteRequests(frames, generations: frameWriteGenerations, forceVerification: false),
            callbackGeneration: callbackGeneration,
            completion: completion
        )
    }

    func enqueueParkFrames(
        _ frames: [AXFrameApplicationRequest],
        callbackGeneration: UInt64,
        completion: @escaping AppAXFrameMailbox.Completion
    ) -> AppAXFrameMailbox.Outcome {
        parkFrameMailbox.enqueue(
            makeFrameWriteRequests(frames, generations: parkFrameWriteGenerations, forceVerification: true),
            callbackGeneration: callbackGeneration,
            completion: completion
        )
    }

    func trackFrameJob(_ job: RunLoopJob, batchId: UUID) {
        activeFrameBatchJobs[batchId] = job
    }

    func trackParkFrameJob(_ job: RunLoopJob) {
        activeParkFrameBatchJob = job
    }

    func trackClosingFrameJob(_ job: RunLoopJob, batchId: UUID) {
        activeClosingFrameBatchJobs[batchId] = job
    }

    func finishFrames(batchId: UUID, drainId: UInt64, results: [AXFrameApplyResult]) -> AppAXFrameMailbox.Outcome {
        activeFrameBatchJobs.removeValue(forKey: batchId)
        return frameMailbox.finish(drainId: drainId, results: results)
    }

    func finishParkFrames(drainId: UInt64, results: [AXFrameApplyResult]) -> AppAXFrameMailbox.Outcome {
        activeParkFrameBatchJob = nil
        return parkFrameMailbox.finish(drainId: drainId, results: results)
    }

    func finishClosingFrames(batchId: UUID, drainId: UInt64, cancelledCount: Int) -> AppAXClosingFrameMailbox.Drain? {
        activeClosingFrameBatchJobs.removeValue(forKey: batchId)
        return closingFrameMailbox.finish(drainId: drainId, cancelledCount: cancelledCount)
    }

    func writer(trace: AppAXFrameWriteTrace) -> AppAXFrameBatchWriter {
        AppAXFrameBatchWriter(
            generations: trace.lane == .park ? parkFrameWriteGenerations : frameWriteGenerations,
            suppression: trace.lane == .park ? nil : frameWriteSuppression,
            hardSuppression: trace.lane == .park ? frameWriteSuppression : nil,
            trace: trace
        )
    }

    func closingExecution(metricsToken: AXWriteMetrics.ContextToken) -> AppAXClosingFrameExecution {
        AppAXClosingFrameExecution(
            generations: closingFrameWriteGenerations,
            suppression: frameWriteSuppression,
            metricsToken: metricsToken
        )
    }

    func shutdown() {
        for (_, job) in activeFrameBatchJobs {
            job.cancel()
        }
        activeFrameBatchJobs = [:]
        for delivery in frameMailbox.beginShutdown() {
            delivery.deliver()
        }
        activeParkFrameBatchJob?.cancel()
        activeParkFrameBatchJob = nil
        for delivery in parkFrameMailbox.beginShutdown() {
            delivery.deliver()
        }
        for (_, job) in activeClosingFrameBatchJobs {
            job.cancel()
        }
        activeClosingFrameBatchJobs = [:]
        closingFrameMailbox.cancelAll()
        closingFrameWriteGenerations.invalidateAll()
    }

    private func makeFrameWriteRequests(
        _ frames: [AXFrameApplicationRequest],
        generations: LockedWindowGenerationMap,
        forceVerification: Bool
    ) -> [AppAXFrameWriteRequest] {
        frames.map {
            AppAXFrameWriteRequest(
                requestId: $0.requestId,
                pid: $0.pid,
                windowId: $0.windowId,
                expectedWindow: $0.expectedWindow,
                frame: $0.frame,
                currentFrameHint: $0.currentFrameHint,
                components: $0.components,
                generation: generations.nextGeneration(for: $0.windowId),
                verify: forceVerification || $0.verify,
                traceRequestId: $0.traceRequestId
            )
        }
    }
}
