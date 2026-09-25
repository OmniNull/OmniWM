// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Dispatch
import Foundation

enum MainThreadAXSpanTrace {
    enum Operation: String, Sendable {
        case fronting
        case activateApp = "activate-app"
        case privateFocus = "private-focus"
        case sameAppDeactivate = "same-app-deactivate"
        case sameAppHandoff = "same-app-handoff"
        case axRaise = "ax-raise"
        case orderWindow = "order-window"
        case closeButtonPress = "close-button-press"
        case setNativeFullscreen = "set-native-fullscreen"
        case readFrame = "read-frame"
        case readSubrole = "read-subrole"
        case readRoleAndSubrole = "read-role-subrole"
        case readFullscreen = "read-fullscreen"
        case readFullscreenAttribute = "read-fullscreen-attribute"
        case readWindowFacts = "read-window-facts"
        case readSizeConstraints = "read-size-constraints"
        case readSizeSettable = "read-size-settable"
        case readProcessIdentifier = "read-pid"
        case lookupWindowRef = "lookup-window-ref"
        case lookupPinnedWindowID = "lookup-pinned-window-id"
        case readApplicationWindows = "read-application-windows"
        case lookupCandidateWindowID = "lookup-candidate-window-id"
        case windowServerBounds = "ws-window-bounds"
        case windowServerQuery = "ws-window-query"
        case windowServerBatchQuery = "ws-window-batch-query"
        case windowServerVisibleQuery = "ws-visible-window-query"
        case windowServerCommit = "ws-transaction-commit"

        var minimumNanoseconds: UInt64 {
            switch self {
            case .windowServerBounds,
                 .windowServerQuery,
                 .windowServerBatchQuery,
                 .windowServerVisibleQuery,
                 .windowServerCommit:
                MainThreadAXSpanTrace.windowServerMinimumNanoseconds
            default:
                0
            }
        }
    }

    struct Record: Sendable {
        let uptimeNs: UInt64
        let operation: Operation
        let pid: pid_t
        let windowId: Int
        let nanoseconds: UInt64
        let succeeded: Bool
        var count: Int?
        var status: Int32?
        var resolvedWindowId: Int?
    }

    static let windowServerMinimumNanoseconds: UInt64 = 1_000_000
    static let capturePolicy = "mainThreadSpans=AX-all,WindowServer-duration-at-least-1000us"

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Main Thread AX Spans",
        capacity: 16_384
    ) { record in
        var line = "scope=main-thread-sync t_ns=\(record.uptimeNs) op=\(record.operation.rawValue)"
            + " pid=\(record.pid) win=\(record.windowId)"
            + " start_ns=\(record.uptimeNs &- record.nanoseconds) end_ns=\(record.uptimeNs)"
            + " total_us=\(String(format: "%.1f", Double(record.nanoseconds) / 1_000))"
            + " outcome=\(record.succeeded ? "success" : "failure")"
        if let count = record.count { line += " count=\(count)" }
        if let status = record.status { line += " status=\(status)" }
        if let resolvedWindowId = record.resolvedWindowId { line += " resolved_win=\(resolvedWindowId)" }
        if record.operation.minimumNanoseconds > 0 {
            line += " minimum_us=\(record.operation.minimumNanoseconds / 1_000)"
        }
        return line
    }

    static func measure<Value, Failure: Error>(
        _ operation: Operation,
        pid: pid_t = 0,
        windowId: Int = 0,
        count: Int? = nil,
        _ body: () throws(Failure) -> Value,
        succeeded: (Value) -> Bool = { _ in true },
        status: (Value) -> Int32? = { _ in nil },
        resolvedWindowId: (Value) -> Int? = { _ in nil }
    ) throws(Failure) -> Value {
        guard shared.isActive, Thread.isMainThread else { return try body() }
        let startedNs = DispatchTime.now().uptimeNanoseconds
        do throws(Failure) {
            let value = try body()
            finish(
                operation, pid: pid, windowId: windowId, startedNs: startedNs,
                succeeded: succeeded(value), count: count, status: status(value),
                resolvedWindowId: resolvedWindowId(value)
            )
            return value
        } catch {
            finish(operation, pid: pid, windowId: windowId, startedNs: startedNs, succeeded: false, count: count)
            throw error
        }
    }

    static func record(_ record: Record) {
        guard record.nanoseconds >= record.operation.minimumNanoseconds else { return }
        shared.record(record)
    }

    private static func finish(
        _ operation: Operation,
        pid: pid_t,
        windowId: Int,
        startedNs: UInt64,
        succeeded: Bool,
        count: Int? = nil,
        status: Int32? = nil,
        resolvedWindowId: Int? = nil
    ) {
        let endNs = DispatchTime.now().uptimeNanoseconds
        record(
            Record(
                uptimeNs: endNs,
                operation: operation,
                pid: pid,
                windowId: windowId,
                nanoseconds: endNs &- startedNs,
                succeeded: succeeded,
                count: count,
                status: status,
                resolvedWindowId: resolvedWindowId
            )
        )
    }
}
