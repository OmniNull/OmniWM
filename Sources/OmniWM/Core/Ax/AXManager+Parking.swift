// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension AXManager {
    func markParkPending(_ target: AXFrameApplicationTarget) {
        parkLedger.markParkPending(target)
    }

    func markParkPending(for windowId: Int, pid: pid_t) {
        parkLedger.markParkPending(for: windowId, pid: pid)
    }

    func clearParkPending(for windowId: Int, pid: pid_t, reason: String = "revealed") {
        parkLedger.clearParkPending(
            for: windowId,
            pid: pid,
            reason: reason
        )
    }

    func pendingParkFrameRequest(for windowId: Int) -> AXFrameApplicationRequest? {
        parkLedger
            .pendingParkFrameRequest(for: windowId)
    }

    func verifiedParkFrame(for windowId: Int) -> CGRect? {
        parkLedger.verifiedParkFrame(for: windowId)
    }

    func parkTargetFrame(for windowId: Int) -> CGRect? {
        parkLedger.parkTargetFrame(for: windowId)
    }

    func processParkFrameApplyResults(_ results: [AXFrameApplyResult]) -> [AXFrameApplicationRequest] {
        parkLedger
            .processParkFrameApplyResults(results)
    }

    @discardableResult
    func cancelParkFrameJobs(
        _ entries: [(pid: pid_t, windowId: Int)],
        reason: String = "shown"
    ) -> Set<WindowToken> {
        parkLedger.cancelParkFrameJobs(
            entries,
            reason: reason
        )
    }
}
