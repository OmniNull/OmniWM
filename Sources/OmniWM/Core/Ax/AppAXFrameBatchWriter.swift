// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation

struct AppAXFrameBatchWriter {
    private let generations: LockedWindowGenerationMap
    private let suppression: LockedWindowIdSet?
    private let hardSuppression: LockedWindowIdSet?
    private let trace: AppAXFrameWriteTrace

    init(
        generations: LockedWindowGenerationMap,
        suppression: LockedWindowIdSet?,
        hardSuppression: LockedWindowIdSet?,
        trace: AppAXFrameWriteTrace
    ) {
        self.generations = generations
        self.suppression = suppression
        self.hardSuppression = hardSuppression
        self.trace = trace
    }

    func execute(
        _ items: Span<AppAXFrameMailbox.Item>,
        axApp: AXUIElement,
        isCancelled: () -> Bool
    ) -> [AXFrameApplyResult] {
        let hasEligibleRequest = hasEligibleRequest(in: items, isCancelled: isCancelled)
        let latencyActive = trace.lane.supportsFrameEffectTracing && AXWriteLatencyTrace.shared.isActive
        guard hasEligibleRequest else {
            return skippedResults(
                for: items,
                trace: latencyActive ? trace : nil,
                isCancelled: isCancelled
            )
        }
        let batchStartNs = latencyActive ? DispatchTime.now().uptimeNanoseconds : 0
        let enhancedUI = AppAXEnhancedUIWriteScope(axApp: axApp, pid: trace.context.pid, tracing: latencyActive)
        var activeTrace = latencyActive ? trace : nil
        activeTrace?.enhancedUI = enhancedUI.wasEnabled
        let results = applyRequests(
            items,
            trace: activeTrace,
            isCancelled: isCancelled
        )
        let timing = enhancedUI.restore()
        activeTrace?.recordBatch(count: items.count, startedNs: batchStartNs, timing: timing)
        return results
    }

    private func hasEligibleRequest(
        in items: Span<AppAXFrameMailbox.Item>,
        isCancelled: () -> Bool
    ) -> Bool {
        var hasEligibleRequest = false
        var staleBeforeIPC = 0
        for index in items.indices {
            let request = items[index].request
            let reason = skipReason(for: request, isCancelled: isCancelled)
            hasEligibleRequest = hasEligibleRequest || reason == nil
            if reason == .cancelled,
               !generations.isCurrent(request.generation, for: request.windowId)
            {
                staleBeforeIPC += 1
            }
        }
        if AppAXContextRuntimeMetrics.shared.isActive {
            AppAXContextRuntimeMetrics.shared.noteStaleBeforeIPC(staleBeforeIPC)
        }
        return hasEligibleRequest
    }

    private func skippedResults(
        for items: Span<AppAXFrameMailbox.Item>,
        trace: AppAXFrameWriteTrace?,
        isCancelled: () -> Bool
    ) -> [AXFrameApplyResult] {
        var results: [AXFrameApplyResult] = []
        results.reserveCapacity(items.count)
        for index in items.indices {
            let item = items[index]
            let request = item.request
            let result = skippedFrameApplyResult(
                for: request,
                reason: skipReason(for: request, isCancelled: isCancelled) ?? .cancelled
            )
            if let trace {
                trace.recordSkipped(request, item: item, result: result)
            }
            results.append(result)
        }
        return results
    }

    private func applyRequests(
        _ items: Span<AppAXFrameMailbox.Item>,
        trace activeTrace: AppAXFrameWriteTrace?,
        isCancelled: () -> Bool
    ) -> [AXFrameApplyResult] {
        var results: [AXFrameApplyResult] = []
        results.reserveCapacity(items.count)
        for index in items.indices {
            let item = items[index]
            let request = item.request
            if let reason = skipReason(for: request, isCancelled: isCancelled) {
                let result = skippedFrameApplyResult(for: request, reason: reason)
                results.append(result)
                if let activeTrace {
                    activeTrace.recordSkipped(request, item: item, result: result)
                }
                continue
            }
            if let activeTrace {
                results.append(applyFrameWriteRequest(
                    request,
                    pid: trace.context.pid,
                    callbackGeneration: trace.context.callbackGeneration,
                    generations: generations,
                    traceLane: trace.lane
                ) { attempt in
                    activeTrace.recordAttempt(request, item: item, attempt: attempt)
                })
            } else {
                results.append(applyFrameWriteRequest(
                    request,
                    pid: trace.context.pid,
                    callbackGeneration: trace.context.callbackGeneration,
                    generations: generations,
                    traceLane: trace.lane
                ))
            }
        }
        return results
    }

    private func skipReason(
        for request: AppAXFrameWriteRequest,
        isCancelled: () -> Bool
    ) -> AXFrameWriteFailureReason? {
        if isCancelled() || !generations.isCurrent(request.generation, for: request.windowId) {
            return .cancelled
        }
        if hardSuppression?.isHardSuppressed(for: request.windowId) == true
            || suppression?.contains(request.windowId) == true
        {
            return .suppressed
        }
        return nil
    }
}
