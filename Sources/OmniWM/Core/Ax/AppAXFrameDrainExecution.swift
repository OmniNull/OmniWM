// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

struct AppAXFrameDrainExecution: Sendable {
    let writer: AppAXFrameBatchWriter
    let axApp: ThreadGuardedValue<AXUIElement>

    func execute(_ drain: AppAXFrameMailbox.Drain, job: RunLoopJob) -> [AXFrameApplyResult] {
        writer.execute(drain.items.span, axApp: axApp.value, isCancelled: { job.isCancelled })
    }
}

struct AppAXClosingFrameExecution: Sendable {
    let generations: LockedClosingFrameGenerationMap
    let suppression: LockedWindowIdSet
    let metricsToken: AXWriteMetrics.ContextToken

    func execute(_ drain: AppAXClosingFrameMailbox.Drain, job: RunLoopJob) -> Int {
        AppAXContextRuntimeMetrics.shared.noteClosingStarted(drain.requests.count)
        var cancelledCount = 0
        for request in drain.requests {
            let outcome = applyClosingFrameWriteRequest(
                request,
                generations: generations,
                isCancelled: {
                    job.isCancelled || suppression.isHardSuppressed(for: request.target.windowId)
                }
            )
            generations.removeIfCurrent(
                request.generation,
                for: request.target.animationId
            )
            switch outcome {
            case .ineligible:
                cancelledCount += 1
            case let .attempted(result, nanoseconds):
                AXWriteMetrics.shared.record(
                    metricsToken,
                    lane: .closing,
                    nanoseconds: nanoseconds,
                    succeeded: result.failureReason == nil
                )
            }
        }
        return cancelledCount
    }
}
