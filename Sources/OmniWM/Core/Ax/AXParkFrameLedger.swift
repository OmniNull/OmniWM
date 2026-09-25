// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class AXParkFrameLedger {
    private struct ParkFrameTargetState {
        let target: AXFrameApplicationTarget
        var isVerified: Bool
    }

    private(set) var pendingParkWindowIds: Set<Int> = []
    private var pendingParkFrameRequestsByWindowId: [Int: AXPendingParkFrameRequest] = [:]
    private var parkFrameTargetStatesByWindowId: [Int: ParkFrameTargetState] = [:]
    private var parkPIDByWindowId: [Int: pid_t] = [:]
    private var nextParkFrameRequestId: AXFrameRequestId = 1

    func markParkPending(_ target: AXFrameApplicationTarget) {
        markParkPending(
            for: target.windowId,
            pid: target.pid,
            target: target,
            cancellationReason: "animation"
        )
    }

    func markParkPending(for windowId: Int, pid: pid_t) {
        markParkPending(
            for: windowId,
            pid: pid,
            target: nil,
            cancellationReason: nil
        )
    }

    func markParkPending(
        for windowId: Int,
        pid: pid_t,
        target: AXFrameApplicationTarget?,
        cancellationReason: String?
    ) {
        let pending = pendingParkFrameRequestsByWindowId.removeValue(forKey: windowId)
        let targetState = parkFrameTargetStatesByWindowId[windowId]
        if let pending {
            AppAXContextRegistry.contexts[pending.request.pid]?.cancelParkFrameJob(for: windowId)
        }
        let retainedTarget = target
            ?? pending.map {
                AXFrameApplicationTarget(
                    pid: $0.request.pid,
                    window: $0.request.expectedWindow,
                    frame: $0.request.frame
                )
            }
            ?? targetState?.target
        if let retainedTarget {
            parkFrameTargetStatesByWindowId[windowId] = ParkFrameTargetState(
                target: retainedTarget,
                isVerified: false
            )
        } else {
            parkFrameTargetStatesByWindowId.removeValue(forKey: windowId)
        }
        pendingParkWindowIds.insert(windowId)
        parkPIDByWindowId[windowId] = pid
        let cancelledTarget = pending?.request.frame
            ?? (targetState?.isVerified == true ? targetState?.target.frame : nil)
        if let cancellationReason, let cancelledTarget {
            FrameApplyTrace.recordEvent(
                pid: pid,
                windowId: windowId,
                outcome: "outcome=ax-park-cancelled/\(cancellationReason)",
                target: cancelledTarget,
                requestId: pending?.request.requestId ?? 0,
                traceRequestId: pending?.request.traceRequestId ?? 0,
                lane: .park
            )
        }
    }

    func clearParkPending(for windowId: Int, pid: pid_t, reason: String = "revealed") {
        cancelParkFrameJobs([(pid: pid, windowId: windowId)], reason: reason)
    }

    func pendingParkFrameRequest(for windowId: Int) -> AXFrameApplicationRequest? {
        pendingParkFrameRequestsByWindowId[windowId]?.request
    }

    func verifiedParkFrame(for windowId: Int) -> CGRect? {
        guard let state = parkFrameTargetStatesByWindowId[windowId],
              state.isVerified
        else {
            return nil
        }
        return state.target.frame
    }

    func parkTargetFrame(for windowId: Int) -> CGRect? {
        parkFrameTargetStatesByWindowId[windowId]?.target.frame
    }

    private func parkFrameFailureReason(for result: AXFrameApplyResult) -> AXFrameWriteFailureReason? {
        if let failureReason = result.writeResult.failureReason {
            return failureReason
        }
        guard let observedFrame = result.writeResult.observedFrame else {
            return .readbackFailed
        }
        guard observedFrame.approximatelyEqual(
            to: result.targetFrame,
            tolerance: FrameTolerance.frameWrite
        ) else {
            return .verificationMismatch
        }
        return nil
    }

    private func makeNextParkFrameRequestId() -> AXFrameRequestId {
        let requestId = nextParkFrameRequestId
        nextParkFrameRequestId &+= 1
        return requestId
    }

    func clearParkFrameState(for pid: pid_t, reason: String) {
        var windowIds = Set(
            parkPIDByWindowId.compactMap { windowId, statePID in
                statePID == pid ? windowId : nil
            }
        )
        for (windowId, pending) in pendingParkFrameRequestsByWindowId
            where pending.request.pid == pid
        {
            windowIds.insert(windowId)
        }
        for (windowId, targetState) in parkFrameTargetStatesByWindowId
            where targetState.target.pid == pid
        {
            windowIds.insert(windowId)
        }
        cancelParkFrameJobs(
            windowIds.map { (pid: pid, windowId: $0) },
            reason: reason
        )
    }

    func resetIncarnationAuxiliaryState(oldWindowId: Int, newWindowId: Int) {
        pendingParkWindowIds.remove(oldWindowId)
        pendingParkWindowIds.remove(newWindowId)
        pendingParkFrameRequestsByWindowId.removeValue(forKey: oldWindowId)
        pendingParkFrameRequestsByWindowId.removeValue(forKey: newWindowId)
        parkFrameTargetStatesByWindowId.removeValue(forKey: oldWindowId)
        parkFrameTargetStatesByWindowId.removeValue(forKey: newWindowId)
        parkPIDByWindowId.removeValue(forKey: oldWindowId)
        parkPIDByWindowId.removeValue(forKey: newWindowId)
    }

    @discardableResult
    func cancelParkFrameJobs(
        _ entries: [(pid: pid_t, windowId: Int)],
        reason: String = "shown"
    ) -> Set<WindowToken> {
        var requiresVisibleAXTokens: Set<WindowToken> = []
        for (pid, windowId) in AXFrameEntryGrouping.unique(entries) {
            let pending = pendingParkFrameRequestsByWindowId.removeValue(forKey: windowId)
            let targetState = parkFrameTargetStatesByWindowId.removeValue(forKey: windowId)
            let statePID = pending?.request.pid ?? targetState?.target.pid ?? parkPIDByWindowId[windowId] ?? pid
            let target = pending?.request.frame ?? targetState?.target.frame
            let hadState = pendingParkWindowIds.remove(windowId) != nil
                || pending != nil
                || targetState != nil
                || parkPIDByWindowId[windowId] != nil
            parkPIDByWindowId.removeValue(forKey: windowId)
            if let pending {
                requiresVisibleAXTokens.insert(
                    WindowToken(pid: pending.request.pid, windowId: windowId)
                )
            }
            if let targetState {
                requiresVisibleAXTokens.insert(
                    WindowToken(pid: targetState.target.pid, windowId: windowId)
                )
            }
            AppAXContextRegistry.contexts[pid]?.cancelParkFrameJob(for: windowId)
            if statePID != pid {
                AppAXContextRegistry.contexts[statePID]?.cancelParkFrameJob(for: windowId)
            }
            if hadState {
                FrameApplyTrace.recordEvent(
                    pid: statePID,
                    windowId: windowId,
                    outcome: "outcome=ax-park-cancelled/\(reason)",
                    target: target,
                    requestId: pending?.request.requestId ?? 0,
                    traceRequestId: pending?.request.traceRequestId ?? 0,
                    lane: .park
                )
            }
        }
        return requiresVisibleAXTokens
    }

    func rebindState(oldWindowId: Int, newWindowId: Int) -> (frame: CGRect?, isPending: Bool) {
        let parkFrame = pendingParkFrameRequestsByWindowId[oldWindowId]?.request.frame
            ?? parkFrameTargetStatesByWindowId[oldWindowId]?.target.frame
            ?? pendingParkFrameRequestsByWindowId[newWindowId]?.request.frame
            ?? parkFrameTargetStatesByWindowId[newWindowId]?.target.frame
        let shouldReissuePark = pendingParkWindowIds.contains(oldWindowId)
            || pendingParkWindowIds.contains(newWindowId)
            || pendingParkFrameRequestsByWindowId[oldWindowId] != nil
            || pendingParkFrameRequestsByWindowId[newWindowId] != nil
            || parkFrameTargetStatesByWindowId[oldWindowId] != nil
            || parkFrameTargetStatesByWindowId[newWindowId] != nil

        return (parkFrame, shouldReissuePark)
    }

    func shutdown() {
        let parkEntries = parkPIDByWindowId.map { (pid: $0.value, windowId: $0.key) }
        cancelParkFrameJobs(parkEntries, reason: "shutdown")
        pendingParkWindowIds.removeAll()
        pendingParkFrameRequestsByWindowId.removeAll()
        parkFrameTargetStatesByWindowId.removeAll()
        parkPIDByWindowId.removeAll()
    }
}

extension AXParkFrameLedger {
    func prepareParkFrameApplications(
        _ frames: [AXFrameApplicationTarget],
        currentFrame: (Int) -> CGRect?
    ) -> [AXFrameApplicationRequest] {
        var requests: [AXFrameApplicationRequest] = []
        requests.reserveCapacity(frames.count)
        let traceOrigin = FrameEffectTraceContext.originForSubmission()

        for target in frames {
            let windowId = target.windowId
            let traceRequestId = traceOrigin.effectId == 0
                ? 0
                : FrameEffectTraceContext.makeRequestTraceId()
            parkPIDByWindowId[windowId] = target.pid

            if let state = parkFrameTargetStatesByWindowId[windowId],
               state.isVerified,
               state.target.pid == target.pid,
               sameAXWindowIdentity(state.target.expectedWindow, target.expectedWindow),
               state.target.frame == target.frame
            {
                target.recordParkVerifiedNoop(traceRequestId: traceRequestId, traceOrigin: traceOrigin)
                pendingParkWindowIds.remove(windowId)
                continue
            }
            pendingParkWindowIds.insert(windowId)

            if let pending = pendingParkFrameRequestsByWindowId[windowId] {
                if pending.request.pid == target.pid,
                   sameAXWindowIdentity(pending.request.expectedWindow, target.expectedWindow),
                   pending.request.frame == target.frame
                {
                    target.recordParkCoalescing(
                        traceRequestId: traceRequestId,
                        traceOrigin: traceOrigin,
                        relatedTraceId: pending.request.traceRequestId
                    )
                    continue
                }
                AppAXContextRegistry.contexts[pending.request.pid]?.cancelParkFrameJob(for: windowId)
                pendingParkFrameRequestsByWindowId.removeValue(forKey: windowId)
                pending.request.recordParkSuperseded(relatedTraceId: traceRequestId)
            }

            let request = registerParkFrameRequest(target, traceRequestId: traceRequestId, currentFrame: currentFrame)
            target.recordParkPreparation(request: request, traceOrigin: traceOrigin)
            requests.append(request)
        }

        return requests.filter {
            pendingParkFrameRequestsByWindowId[$0.windowId]?.request.requestId == $0.requestId
        }
    }

    func processParkFrameApplyResults(
        _ results: [AXFrameApplyResult]
    ) -> [AXFrameApplicationRequest] {
        var retries: [AXFrameApplicationRequest] = []
        retries.reserveCapacity(results.count)

        for result in results {
            let windowId = result.windowId
            guard let pending = pendingParkFrameRequestsByWindowId[windowId],
                  pending.request.requestId == result.requestId,
                  pending.request.pid == result.pid,
                  sameAXWindowIdentity(pending.request.expectedWindow, result.expectedWindow),
                  pending.request.frame == result.targetFrame
            else {
                continue
            }

            pendingParkFrameRequestsByWindowId.removeValue(forKey: windowId)
            let failureReason = parkFrameFailureReason(for: result)
            guard let failureReason else {
                parkFrameTargetStatesByWindowId[windowId] = ParkFrameTargetState(
                    target: AXFrameApplicationTarget(
                        pid: result.pid,
                        window: result.expectedWindow,
                        frame: result.targetFrame
                    ),
                    isVerified: true
                )
                parkPIDByWindowId[windowId] = result.pid
                pendingParkWindowIds.remove(windowId)
                result.recordParkConfirmation()
                continue
            }

            if failureReason == .cancelled {
                result.recordParkCancellation()
                continue
            }

            result.recordParkFailure(failureReason)
            guard pending.retriesRemaining > 0,
                  pendingParkWindowIds.contains(windowId)
            else {
                continue
            }

            let retry = pending.retry(requestId: makeNextParkFrameRequestId())
            pendingParkFrameRequestsByWindowId[windowId] = AXPendingParkFrameRequest(
                request: retry,
                retriesRemaining: pending.retriesRemaining - 1
            )
            retry.recordParkRetry(parentTraceId: pending.request.traceRequestId)
            retries.append(retry)
        }

        return retries
    }

    private func registerParkFrameRequest(
        _ target: AXFrameApplicationTarget,
        traceRequestId: UInt64,
        currentFrame: (Int) -> CGRect?
    ) -> AXFrameApplicationRequest {
        parkFrameTargetStatesByWindowId[target.windowId] = ParkFrameTargetState(
            target: target,
            isVerified: false
        )
        let request = AXFrameApplicationRequest(
            requestId: makeNextParkFrameRequestId(),
            pid: target.pid,
            windowId: target.windowId,
            expectedWindow: target.expectedWindow,
            frame: target.frame,
            currentFrameHint: currentFrame(target.windowId),
            components: .position,
            verify: true,
            traceRequestId: traceRequestId
        )
        pendingParkFrameRequestsByWindowId[target.windowId] = AXPendingParkFrameRequest(
            request: request,
            retriesRemaining: 1
        )
        return request
    }
}
