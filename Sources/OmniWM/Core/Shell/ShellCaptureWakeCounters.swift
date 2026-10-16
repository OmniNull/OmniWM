// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

struct ShellCaptureWakeCounters: Equatable, Sendable {
    var emitted: UInt64 = 0
    var consumed: UInt64 = 0
    var pending: UInt64 = 0
    var peak: UInt64 = 0

    mutating func emit() {
        emitted &+= 1
        pending &+= 1
        peak = max(peak, pending)
    }

    mutating func consume() {
        consumed &+= 1
        if pending > 0 { pending -= 1 }
    }

    var detail: String {
        "wake_emitted=\(emitted) wake_consumed=\(consumed) capture_pending_wakes=\(pending)"
            + " capture_pending_wake_peak=\(peak) precapture_pending_excluded=true"
    }
}
