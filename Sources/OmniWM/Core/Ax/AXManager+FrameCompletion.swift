// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension AXManager {
    func handleFrameApplyResults(
        _ results: [AXFrameApplyResult],
        applyParkPosition: (SkyLightPositionTarget) -> SkyLight.TransactionSubmissionResult = {
            SkyLight.shared.batchMoveWindows(AXManager.windowServerPositions([$0]))
        }
    ) {
        for result in results {
            FrameApplyTrace.recordResult(result)
        }
        let outcome = frameLedger.handleFrameApplyResults(results, onAcceptedSuccess: { [weak self] result in
            self?.handleAcceptedFrameApplySuccess(result)
        }, onDiscardedResult: { [weak self] result in
            self?.restoreParkAfterDiscardedWrite(result, applyPosition: applyParkPosition)
        })
        for retry in outcome.retries {
            FrameApplyTrace.recordEvent(
                pid: retry.pid,
                windowId: retry.windowId,
                outcome: "outcome=retry-scheduled",
                target: retry.frame,
                requestId: retry.requestId,
                traceRequestId: retry.traceRequestId
            )
            scheduleFrameRetry(retry)
        }
        for delivery in outcome.deliveries {
            delivery.deliver()
        }
        for refusal in outcome.terminalRefusals {
            FrameApplyTrace.recordEvent(
                pid: refusal.pid,
                windowId: refusal.windowId,
                outcome: "outcome=terminal-refusal/\(refusal.failureReason.traceDescription)",
                target: refusal.targetFrame,
                observed: refusal.observedFrame,
                requestId: refusal.requestId,
                traceRequestId: refusal.traceRequestId
            )
            onTerminalFrameRefusal?(refusal)
        }
        for terminalFailure in outcome.terminalFailures {
            handleTerminalFrameApplyFailure(terminalFailure)
        }
        for result in outcome.stableSizeClamps {
            onStableSizeClamp?(result)
        }
    }

    private func restoreParkAfterDiscardedWrite(
        _ result: AXFrameApplyResult,
        applyPosition: (SkyLightPositionTarget) -> SkyLight.TransactionSubmissionResult
    ) {
        guard result.didAttemptWrite,
              isWindowParked?(result.windowId) == true,
              let target = parkLedger.parkTarget(matching: result)
        else { return }
        let position = SkyLightPositionTarget(
            token: WindowToken(pid: target.pid, windowId: target.windowId),
            frame: target.frame
        )
        guard !positionsAllowedToWrite([position], allowInactive: true).isEmpty else { return }
        clearSkyLightLivePosition(for: target.windowId)
        parkLedger.markParkPending(target)
        let submission = applyPosition(position)
        if submission == .submitted {
            recordSkyLightMove(windowId: target.windowId, origin: target.frame.origin)
        }
        FrameApplyTrace.recordEvent(
            pid: target.pid,
            windowId: target.windowId,
            outcome: "outcome=park-reasserted/stale-write/\(submission)",
            target: target.frame,
            requestId: result.requestId,
            traceRequestId: result.traceRequestId,
            lane: .park
        )
        applyParkFramesParallel([target])
    }

    func handleAcceptedFrameApplySuccess(_ result: AXFrameApplyResult) {
        clearSkyLightLivePosition(for: result.windowId)
        if isWindowParked?(result.windowId) == true {
            parkLedger.markParkPending(
                for: result.windowId,
                pid: result.pid,
                target: nil,
                cancellationReason: "ordinary-write"
            )
        }
        onFrameApplySucceeded?(result)
    }

    func handleTerminalFrameApplyFailure(_ result: AXFrameApplyResult) {
        let reason = result.writeResult.failureReason?.traceDescription ?? "unconfirmed"
        FrameApplyTrace.recordEvent(
            pid: result.pid,
            windowId: result.windowId,
            outcome: "outcome=terminal-failure/\(reason)",
            target: result.targetFrame,
            requestId: result.requestId,
            traceRequestId: result.traceRequestId
        )
        onFrameApplyTerminated?(result)
    }
}
