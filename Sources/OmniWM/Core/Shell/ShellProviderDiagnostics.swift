// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellProviderDiagnostics {
    static let lineLimit = 1024
    static let reportLimit = 20
    static let interval: UInt64 = 10_000_000_000

    struct Line: Equatable, Sendable {
        let text: String
        let truncated: Bool
        let suppressed: UInt64
    }

    private var partial: [UInt8] = []
    private var truncated = false
    private var windowStart: UInt64?
    private var reported = 0
    private(set) var suppressed: UInt64 = 0
    private(set) var truncatedLines: UInt64 = 0

    var bufferedBytes: Int {
        partial.count
    }

    mutating func consume(_ bytes: UnsafeRawBufferPointer, now: UInt64, receive: (Line) -> Void) {
        for byte in bytes {
            if byte == 10 { finishLine(now: now, receive: receive) }
            else if partial.count < Self.lineLimit { partial.append(byte) }
            else { truncated = true }
        }
    }

    mutating func finish(now: UInt64, receive: (Line) -> Void) {
        if !partial.isEmpty || truncated { finishLine(now: now, receive: receive) }
    }

    private mutating func finishLine(now: UInt64, receive: (Line) -> Void) {
        if windowStart == nil || (now >= windowStart! && now - windowStart! >= Self.interval) {
            windowStart = now
            reported = 0
        }
        if truncated, truncatedLines != .max { truncatedLines += 1 }
        if reported < Self.reportLimit {
            receive(Line(text: String(decoding: partial, as: UTF8.self), truncated: truncated, suppressed: suppressed))
            reported += 1
            suppressed = 0
        } else if suppressed != .max {
            suppressed += 1
        }
        partial.removeAll(keepingCapacity: true)
        truncated = false
    }
}
