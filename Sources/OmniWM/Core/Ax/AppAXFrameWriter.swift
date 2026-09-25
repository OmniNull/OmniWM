// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

enum AXClosingFrameWriteOutcome: Equatable {
    case ineligible
    case attempted(AXFrameWriteResult, nanoseconds: UInt64)
}

func applyClosingFrameWriteRequest(
    _ request: AppAXClosingFrameWriteRequest,
    generations: LockedClosingFrameGenerationMap,
    isCancelled: () -> Bool = { false },
    writeFrame: (AXWindowRef, CGRect, CGRect?, Bool) -> AXFrameWriteResult = {
        AXWindowService.setFrame($0, frame: $1, currentFrameHint: $2, verify: $3)
    }
) -> AXClosingFrameWriteOutcome {
    guard !isCancelled(),
          generations.isCurrent(request.generation, for: request.target.animationId)
    else {
        return .ineligible
    }
    let startedNs = DispatchTime.now().uptimeNanoseconds
    let result = writeFrame(
        request.target.expectedWindow,
        request.target.frame,
        request.target.currentFrameHint,
        false
    )
    return .attempted(result, nanoseconds: DispatchTime.now().uptimeNanoseconds &- startedNs)
}

func applyFrameWriteRequest(
    _ request: AppAXFrameWriteRequest,
    pid: pid_t,
    callbackGeneration: UInt64 = 0,
    generations: LockedWindowGenerationMap,
    writeFrame: (AXWindowRef, CGRect, CGRect?, AXFrameComponents, Bool) -> AXFrameWriteResult = {
        AXWindowService.setFrame($0, frame: $1, currentFrameHint: $2, components: $3, verify: $4)
    },
    refreshWindow: (UInt32, pid_t) -> AXWindowRef? = {
        AXWindowService.axWindowRef(for: $0, pid: $1)
    },
    traceLane: AppAXFrameLane = .ordinary,
    traceAttempt: ((AppAXFrameWriteAttempt) -> Void)? = nil
) -> AXFrameApplyResult {
    let windowId = request.windowId

    let metricsToken = AXWriteMetrics.ContextToken(pid: pid, callbackGeneration: callbackGeneration)
    var didAttemptWrite = false

    func performWrite(_ window: AXWindowRef, attempt: UInt8) -> AXFrameWriteResult {
        let result: AXFrameWriteResult
        if let traceAttempt {
            result = AppAXFrameTraceContext(request: request, metricsToken: metricsToken, lane: traceLane)
                .write(window, attempt: attempt, traceAttempt: traceAttempt)
        } else {
            result = AXWriteMetrics.shared.measure(metricsToken, lane: traceLane) {
                writeFrame(window, request.frame, request.currentFrameHint, request.components, request.verify)
            } succeeded: { $0.failureReason == nil }
        }
        didAttemptWrite = didAttemptWrite || result.failureReason != .valueCreationFailed
        return result
    }

    let expectedWindow = request.expectedWindow
    guard generations.isCurrent(request.generation, for: windowId) else {
        return cancelledFrameApplyResult(for: request)
    }
    let initialResult = performWrite(expectedWindow, attempt: 1)
    guard generations.isCurrent(request.generation, for: windowId) else {
        return cancelledFrameApplyResult(for: request, didAttemptWrite: didAttemptWrite)
    }
    if initialResult.shouldRetryAfterRefresh,
       generations.isCurrent(request.generation, for: windowId),
       let refreshedAXRef = refreshWindow(UInt32(windowId), pid)
    {
        guard AppAXContext.acceptsRefreshedFrameElement(
            cachedElement: expectedWindow.element,
            refreshedElement: refreshedAXRef.element,
            windowId: windowId,
            requestGeneration: request.generation,
            generations: generations
        ) else {
            return cancelledFrameApplyResult(for: request, didAttemptWrite: didAttemptWrite)
        }
        guard generations.isCurrent(request.generation, for: windowId) else {
            return cancelledFrameApplyResult(for: request, didAttemptWrite: didAttemptWrite)
        }
        let retryResult = performWrite(refreshedAXRef, attempt: 2)
        guard generations.isCurrent(request.generation, for: windowId) else {
            return cancelledFrameApplyResult(for: request, didAttemptWrite: didAttemptWrite)
        }
        return request.applyResult(pid: pid, writeResult: retryResult, didAttemptWrite: didAttemptWrite)
    }

    return request.applyResult(pid: pid, writeResult: initialResult, didAttemptWrite: didAttemptWrite)
}

private func cancelledFrameApplyResult(
    for request: AppAXFrameWriteRequest,
    didAttemptWrite: Bool = false
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
            failureReason: .cancelled,
            components: request.components
        ),
        didAttemptWrite: didAttemptWrite,
        traceRequestId: request.traceRequestId
    )
}

private struct AppAXFrameTraceContext {
    let request: AppAXFrameWriteRequest
    let metricsToken: AXWriteMetrics.ContextToken
    let lane: AppAXFrameLane

    func write(
        _ window: AXWindowRef,
        attempt: UInt8,
        traceAttempt: (AppAXFrameWriteAttempt) -> Void
    ) -> AXFrameWriteResult {
        let startedNs = DispatchTime.now().uptimeNanoseconds
        FrameEffectObservationTracker.shared.register(
            request,
            pid: metricsToken.pid,
            lane: lane,
            attempt: attempt,
            startedNs: startedNs
        )
        let traced = AXWriteMetrics.shared.measure(metricsToken, lane: lane) {
            AXWindowService.setFrameTraced(
                window,
                frame: request.frame,
                currentFrameHint: request.currentFrameHint,
                components: request.components,
                verify: request.verify
            )
        } succeeded: { $0.result.failureReason == nil }
        traceAttempt(.init(number: attempt, startedNs: startedNs, timing: traced.timing, result: traced.result))
        return traced.result
    }
}

extension AppAXFrameWriteRequest {
    fileprivate func applyResult(
        pid: pid_t,
        writeResult: AXFrameWriteResult,
        didAttemptWrite: Bool
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: requestId,
            pid: pid,
            windowId: windowId,
            expectedWindow: expectedWindow,
            targetFrame: frame,
            currentFrameHint: currentFrameHint,
            writeResult: writeResult,
            didAttemptWrite: didAttemptWrite,
            traceRequestId: traceRequestId
        )
    }
}
