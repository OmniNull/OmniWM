// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

extension AppAXContext {
    func setClosingFramesBatch(_ frames: [AXClosingFrameTarget]) {
        guard let thread = axThread, !frames.isEmpty else { return }
        if let drain = frameDelivery.enqueueClosingFrames(frames) {
            scheduleClosingFrameDrain(drain, on: thread)
        }
    }

    func setFramesBatch(
        _ frames: [AXFrameApplicationRequest],
        completion: @escaping @MainActor ([AXFrameApplyResult]) -> Void
    ) {
        guard let thread = axThread else {
            completion(unavailableFrameApplyResults(for: frames))
            return
        }
        let outcome = frameDelivery.enqueueFrames(
            frames,
            callbackGeneration: callbackGeneration,
            completion: completion
        )
        for delivery in outcome.deliveries {
            delivery.deliver()
        }
        if let drain = outcome.drain {
            scheduleFrameDrain(drain, on: thread)
        }
    }

    func setParkFramesBatch(
        _ frames: [AXFrameApplicationRequest],
        completion: @escaping @MainActor ([AXFrameApplyResult]) -> Void
    ) {
        guard let thread = axThread else {
            completion(unavailableFrameApplyResults(for: frames))
            return
        }
        let outcome = frameDelivery.enqueueParkFrames(
            frames,
            callbackGeneration: callbackGeneration,
            completion: completion
        )
        for delivery in outcome.deliveries {
            delivery.deliver()
        }
        if let drain = outcome.drain {
            scheduleParkFrameDrain(drain, on: thread)
        }
    }

    private func unavailableFrameApplyResults(
        for frames: [AXFrameApplicationRequest]
    ) -> [AXFrameApplyResult] {
        frames.map {
            AXFrameApplyResult(
                requestId: $0.requestId,
                pid: $0.pid,
                windowId: $0.windowId,
                expectedWindow: $0.expectedWindow,
                targetFrame: $0.frame,
                currentFrameHint: $0.currentFrameHint,
                writeResult: .skipped(
                    targetFrame: $0.frame,
                    currentFrameHint: $0.currentFrameHint,
                    failureReason: .contextUnavailable,
                    components: $0.components
                ),
                traceRequestId: $0.traceRequestId
            )
        }
    }

    private func scheduleFrameDrain(
        _ drain: AppAXFrameMailbox.Drain,
        on thread: Thread
    ) {
        nonisolated(unsafe) let appThread = thread
        let batchId = UUID()
        let execution = makeFrameDrainExecution(drainId: drain.id, lane: .ordinary)

        let batchJob = appThread.runInLoopAsync(autoCheckCancelled: false) { [self, execution] job in
            AppAXContextRuntimeMetrics.shared.noteOrdinaryStarted(drain.items)
            let results = execution.execute(drain, job: job)
            scheduleOnMainRunLoop { [weak self] in
                guard let self else { return }
                let outcome = frameDelivery.finishFrames(batchId: batchId, drainId: drain.id, results: results)
                for delivery in outcome.deliveries {
                    delivery.deliver()
                }
                if let nextDrain = outcome.drain, let nextThread = self.axThread {
                    scheduleFrameDrain(nextDrain, on: nextThread)
                }
            }
        }
        frameDelivery.trackFrameJob(batchJob, batchId: batchId)
    }

    private func scheduleParkFrameDrain(
        _ drain: AppAXFrameMailbox.Drain,
        on thread: Thread
    ) {
        nonisolated(unsafe) let appThread = thread
        let execution = makeFrameDrainExecution(drainId: drain.id, lane: .park)

        let batchJob = appThread.runInLoopAsync(autoCheckCancelled: false) { [self, execution] job in
            AppAXContextRuntimeMetrics.shared.noteParkStarted(drain.items)
            let results = execution.execute(drain, job: job)
            scheduleOnMainRunLoop { [weak self] in
                guard let self else { return }
                let outcome = frameDelivery.finishParkFrames(drainId: drain.id, results: results)
                for delivery in outcome.deliveries {
                    delivery.deliver()
                }
                if let nextDrain = outcome.drain, let nextThread = self.axThread {
                    scheduleParkFrameDrain(nextDrain, on: nextThread)
                }
            }
        }
        frameDelivery.trackParkFrameJob(batchJob)
    }

    private func scheduleClosingFrameDrain(
        _ drain: AppAXClosingFrameMailbox.Drain,
        on thread: Thread
    ) {
        nonisolated(unsafe) let appThread = thread
        let batchId = UUID()
        let execution = frameDelivery.closingExecution(metricsToken: writeMetricsToken)
        let batchJob = appThread.runInLoopAsync(autoCheckCancelled: false) { [self] job in
            let cancelledCount = execution.execute(drain, job: job)
            scheduleOnMainRunLoop { [weak self] in
                guard let self else { return }
                if let nextDrain = frameDelivery.finishClosingFrames(
                       batchId: batchId, drainId: drain.id,
                       cancelledCount: cancelledCount
                   ),
                   let nextThread = self.axThread
                {
                    scheduleClosingFrameDrain(nextDrain, on: nextThread)
                }
            }
        }
        frameDelivery.trackClosingFrameJob(batchJob, batchId: batchId)
    }
}
