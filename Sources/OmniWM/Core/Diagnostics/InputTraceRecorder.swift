// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import os

enum InputTrace {
    struct Record: Sendable {
        let timestamp: Date
        let uptimeNs: UInt64
        let detail: String
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Input Trace",
        capacity: 1024
    ) { record in
        "\(record.timestamp.ISO8601Format()) t_ns=\(record.uptimeNs) \(record.detail)"
    }

    static func record(_ detail: @autoclosure () -> String) {
        guard shared.isActive else { return }
        shared.record(Record(timestamp: Date(), uptimeNs: DispatchTime.now().uptimeNanoseconds, detail: detail()))
    }
}

enum InputTapHealth {
    struct Counters: Sendable, Equatable {
        var mouseDisableCount = 0
        var hyperDisableCount = 0
        var lastDisable: Date?
    }

    private static let state = OSAllocatedUnfairLock(initialState: Counters())

    static func recordTapDisabled(mouse: Bool, byTimeout: Bool) {
        state.withLock { counters in
            if mouse {
                counters.mouseDisableCount += 1
            } else {
                counters.hyperDisableCount += 1
            }
            counters.lastDisable = Date()
        }
        let tap = mouse ? "mouse" : "hyper"
        let cause = byTimeout ? "timeout" : "userInput"
        DiagnosticsEventRecorder.shared.recordLifecycle(name: "input.tap.\(tap).disabled.\(cause)")
    }

    static var counters: Counters {
        state.withLock { $0 }
    }
}
