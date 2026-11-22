// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum WindowFocusDispatchTrace {
    struct Record: Sendable {
        let pid: pid_t
        let windowId: UInt32
        let enqueuedNs: UInt64
        let startedNs: UInt64
        let endedNs: UInt64
        let completedNs: UInt64
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Window Focus Dispatch",
        capacity: 4_096
    ) { record in
        "scope=window-focus-dispatch t_ns=\(record.completedNs) op=private-focus pid=\(record.pid) win=\(record.windowId)"
            + " enqueued_ns=\(record.enqueuedNs) start_ns=\(record.startedNs) end_ns=\(record.endedNs)"
            + " completed_ns=\(record.completedNs)"
            + " queue_us=\(String(format: "%.1f", Double(record.startedNs &- record.enqueuedNs) / 1_000))"
            + " total_us=\(String(format: "%.1f", Double(record.endedNs &- record.startedNs) / 1_000))"
            + " main_hop_us=\(String(format: "%.1f", Double(record.completedNs &- record.endedNs) / 1_000))"
    }

    struct RetryRaiseRecord: Sendable {
        let pid: pid_t
        let windowId: Int
        let postedNs: UInt64
        let startedNs: UInt64
        let waitedNs: UInt64
        let endedNs: UInt64
        let raised: Bool
    }

    static let retryRaise = SessionTraceRecorder<RetryRaiseRecord>(
        sectionTitle: "Worker Retry Raise",
        capacity: 4_096
    ) { record in
        "scope=worker-retry-raise t_ns=\(record.endedNs) pid=\(record.pid) win=\(record.windowId)"
            + " posted_ns=\(record.postedNs) start_ns=\(record.startedNs) waited_ns=\(record.waitedNs)"
            + " end_ns=\(record.endedNs)"
            + " queue_us=\(String(format: "%.1f", Double(record.startedNs &- record.postedNs) / 1_000))"
            + " wait_us=\(String(format: "%.1f", Double(record.waitedNs &- record.startedNs) / 1_000))"
            + " raise_us=\(String(format: "%.1f", Double(record.endedNs &- record.waitedNs) / 1_000))"
            + " raised=\(record.raised)"
    }

    static func traceRetryRaise(
        pid: pid_t,
        windowId: Int,
        postedNs: UInt64,
        startedNs: UInt64,
        _ raise: () -> Bool
    ) {
        guard postedNs != 0 else {
            _ = raise()
            return
        }
        let waitedNs = DispatchTime.now().uptimeNanoseconds
        let raised = raise()
        retryRaise.record(
            .init(
                pid: pid,
                windowId: windowId,
                postedNs: postedNs,
                startedNs: startedNs,
                waitedNs: waitedNs,
                endedNs: DispatchTime.now().uptimeNanoseconds,
                raised: raised
            )
        )
    }
}
