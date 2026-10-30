// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct AXFrameBatchOptions {
    let isRetry: Bool
    let verify: Bool
    let terminalObserver: AXFrameApplicationTerminalObserver?
    let parentTraceRequestId: UInt64
}

extension AXManager {
    func beginPIDBufferRuntimeCapture() {
        frameBatchBuffer.beginPIDBufferRuntimeCapture()
    }

    func endPIDBufferRuntimeCapture() {
        frameBatchBuffer.endPIDBufferRuntimeCapture()
    }

    func pidBufferRuntimeSnapshot() -> AXManagerPIDBufferRuntimeSnapshot {
        frameBatchBuffer.pidBufferRuntimeSnapshot()
    }

    func enqueueFrameApplications(
        _ frames: [AXFrameApplicationTarget],
        isRetry: Bool,
        verify: Bool = true,
        terminalObserver: FrameApplicationTerminalObserver? = nil,
        parentTraceRequestId: UInt64 = 0
    ) {
        frameBatchBuffer.withBuffer(targetCount: frames.count) { framesByPid in
            enqueueFrameApplicationsUsingBuffer(
                frames,
                options: AXFrameBatchOptions(
                    isRetry: isRetry,
                    verify: verify,
                    terminalObserver: terminalObserver,
                    parentTraceRequestId: parentTraceRequestId
                ),
                framesByPid: &framesByPid
            )
        }
    }

    func rejectInWorkspaceFrameSettlements(_ target: AXFrameApplicationTarget) {
        for settlement in workspaceFrameSettlements {
            settlement.reject(target)
        }
    }

    private func workspaceFrameSettlementObserver(
        for target: AXFrameApplicationTarget,
        after observer: FrameApplicationTerminalObserver?
    ) -> FrameApplicationTerminalObserver? {
        let settlementObservers = workspaceFrameSettlements.compactMap { $0.observe(target) }
        guard !settlementObservers.isEmpty else { return observer }
        return { result in
            observer?(result)
            for settlementObserver in settlementObservers {
                settlementObserver(result)
            }
        }
    }

    private func enqueueFrameApplicationsUsingBuffer(
        _ frames: [AXFrameApplicationTarget],
        options: AXFrameBatchOptions,
        framesByPid: inout [pid_t: [AXFrameApplicationRequest]]
    ) {
        framesByPid.reserveCapacity(min(frames.count, 8))
        var deferredDeliveries: [AXFrameTerminalDelivery] = []
        let activeParentTraceRequestId = FrameEffectTraceContext.isCurrentCapture(
            identifier: options.parentTraceRequestId
        ) ? options.parentTraceRequestId : 0
        let traceOrigin = activeParentTraceRequestId == 0
            ? FrameEffectTraceContext.originForSubmission()
            : .none

        for target in frames {
            let pid = target.pid
            let windowId = target.windowId
            if inactiveWorkspaceWindowIds.contains(windowId) {
                rejectInWorkspaceFrameSettlements(target)
                continue
            }
            let terminalObserver = options.isRetry
                ? options.terminalObserver
                : workspaceFrameSettlementObserver(for: target, after: options.terminalObserver)
            let decision = frameLedger.prepareFrameApplication(
                target,
                isRetry: options.isRetry,
                verify: options.verify,
                terminalObserver: terminalObserver,
                traceOrigin: traceOrigin,
                parentTraceRequestId: activeParentTraceRequestId
            )
            if decision.shouldCancelPendingRetry {
                cancelPendingFrameRetry(for: windowId)
            }
            deferredDeliveries.append(contentsOf: decision.deliveries)
            guard let request = decision.request else { continue }
            if framesByPid[pid] == nil {
                framesByPid[pid] = []
                framesByPid[pid]?.reserveCapacity(8)
            }
            framesByPid[pid, default: []].append(request)
        }

        dispatchFrameApplications(framesByPid)

        for delivery in deferredDeliveries {
            delivery.deliver()
        }
    }

    private func dispatchFrameApplications(_ framesByPid: [pid_t: [AXFrameApplicationRequest]]) {
        for (pid, appFrames) in framesByPid where !appFrames.isEmpty {
            guard let context = AppAXContextRegistry.contexts[pid] else {
                handleFrameApplyResults(
                    appFrames.map {
                        AXFrameApplyResult(
                            requestId: $0.requestId,
                            pid: pid,
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
                )
                continue
            }
            context.setFramesBatch(appFrames) { [weak self] results in
                self?.handleFrameApplyResults(results)
            }
        }
    }
}
