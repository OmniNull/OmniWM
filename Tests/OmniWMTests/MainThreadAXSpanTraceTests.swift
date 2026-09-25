// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import os
import XCTest

@MainActor
final class MainThreadAXSpanTraceTests: XCTestCase {
    func testSpansRecordOnlyOnTheMainThreadWhileACaptureIsActive() {
        let trace = MainThreadAXSpanTrace.shared
        trace.endCapture()
        trace.releaseStorage()
        var calls = 0

        let inactive = MainThreadAXSpanTrace.measure(.readFrame, pid: 7, windowId: 9) {
            calls += 1
            return 41
        }
        XCTAssertEqual(inactive, 41)
        XCTAssertEqual(trace.dump(), "none")

        trace.beginCapture()
        defer {
            trace.endCapture()
            trace.releaseStorage()
        }
        let onMain = MainThreadAXSpanTrace.measure(.readFrame, pid: 7, windowId: 9) {
            calls += 1
            return 42
        } succeeded: { $0 == 42 }
        let offMainResult = OSAllocatedUnfairLock(initialState: 0)
        let offMainDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let value = MainThreadAXSpanTrace.measure(.readSubrole, pid: 7, windowId: 9) { 43 }
            offMainResult.withLock { $0 = value }
            offMainDone.signal()
        }
        offMainDone.wait()
        let offMain = offMainResult.withLock { $0 }

        XCTAssertEqual(onMain, 42)
        XCTAssertEqual(offMain, 43)
        XCTAssertEqual(calls, 2)
        let dump = trace.dump()
        XCTAssertTrue(dump.contains("scope=main-thread-sync"))
        XCTAssertTrue(dump.contains("op=read-frame pid=7 win=9"))
        XCTAssertTrue(dump.contains("outcome=success"))
        XCTAssertFalse(dump.contains("read-subrole"))
    }

    func testThrowingSpanRecordsAFailureAndRethrows() {
        let trace = MainThreadAXSpanTrace.shared
        trace.beginCapture()
        defer {
            trace.endCapture()
            trace.releaseStorage()
        }

        XCTAssertThrowsError(
            try MainThreadAXSpanTrace.measure(.readFrame, windowId: 3) { () throws(AXErrorWrapper) -> CGRect in
                throw .cannotGetAttribute
            }
        )
        let failed = MainThreadAXSpanTrace
            .measure(.setNativeFullscreen, pid: 5, windowId: 6) { false } succeeded: { $0 }

        XCTAssertFalse(failed)
        let dump = trace.dump()
        XCTAssertTrue(dump.contains("op=read-frame pid=0 win=3"))
        XCTAssertTrue(dump.contains("op=set-native-fullscreen pid=5 win=6"))
        XCTAssertEqual(dump.components(separatedBy: "outcome=failure").count - 1, 2)
        XCTAssertFalse(dump.contains("outcome=success"))
    }

    func testLookupSubspansPreserveStatusCountAndNestedTimes() throws {
        let trace = MainThreadAXSpanTrace.shared
        trace.beginCapture()
        defer {
            trace.endCapture()
            trace.releaseStorage()
        }

        let result = MainThreadAXSpanTrace.measure(.lookupWindowRef, pid: 7, windowId: 9) {
            MainThreadAXSpanTrace.measure(.lookupCandidateWindowID, pid: 7, windowId: 9, count: 10) {
                Int32(0)
            } succeeded: { $0 == 0 } status: { $0 } resolvedWindowId: { _ in 10 }
        } succeeded: { $0 == 0 }

        XCTAssertEqual(result, 0)
        let lines = trace.dump().split(separator: "\n")
        let inner = try XCTUnwrap(lines.first { $0.contains("op=lookup-candidate-window-id") })
        let outer = try XCTUnwrap(lines.first { $0.contains("op=lookup-window-ref") })
        XCTAssertTrue(inner.contains("pid=7 win=9"))
        XCTAssertTrue(inner.contains("count=10 status=0 resolved_win=10"))
        XCTAssertTrue(inner.contains("outcome=success"))
        let innerTimes = try timestamps(in: inner)
        let outerTimes = try timestamps(in: outer)
        XCTAssertLessThanOrEqual(outerTimes.start, innerTimes.start)
        XCTAssertLessThanOrEqual(innerTimes.start, innerTimes.end)
        XCTAssertLessThanOrEqual(innerTimes.end, outerTimes.end)
    }

    func testWindowServerDurationFilterDoesNotFilterAXSpans() {
        let trace = MainThreadAXSpanTrace.shared
        trace.beginCapture()
        defer {
            trace.endCapture()
            trace.releaseStorage()
        }
        let minimum = MainThreadAXSpanTrace.windowServerMinimumNanoseconds
        let operations: [MainThreadAXSpanTrace.Operation] = [
            .windowServerBounds, .windowServerQuery, .windowServerBatchQuery,
            .windowServerVisibleQuery, .windowServerCommit
        ]
        for operation in operations {
            for (windowId, duration) in [(1, minimum - 1), (2, minimum)] {
                MainThreadAXSpanTrace.record(
                    .init(
                        uptimeNs: 10_000_000,
                        operation: operation,
                        pid: 7,
                        windowId: windowId,
                        nanoseconds: duration,
                        succeeded: true
                    )
                )
            }
        }
        MainThreadAXSpanTrace.record(
            .init(
                uptimeNs: 10_000_000,
                operation: .lookupPinnedWindowID,
                pid: 7,
                windowId: 3,
                nanoseconds: 1,
                succeeded: false
            )
        )

        let dump = trace.dump()
        XCTAssertFalse(dump.contains("win=1 "))
        XCTAssertEqual(dump.components(separatedBy: "minimum_us=1000").count - 1, operations.count)
        XCTAssertTrue(dump.contains("start_ns=9000000 end_ns=10000000"))
        XCTAssertTrue(dump.contains("op=lookup-pinned-window-id pid=7 win=3"))
        XCTAssertTrue(dump.contains("outcome=failure"))
        XCTAssertTrue(MainThreadAXSpanTrace.capturePolicy.contains("1000us"))
    }

    private func timestamps(in line: Substring) throws -> (start: UInt64, end: UInt64) {
        let fields = line.split(separator: " ")
        let start = try XCTUnwrap(fields.first { $0.hasPrefix("start_ns=") })
        let end = try XCTUnwrap(fields.first { $0.hasPrefix("end_ns=") })
        return try (
            XCTUnwrap(UInt64(start.dropFirst("start_ns=".count))),
            XCTUnwrap(UInt64(end.dropFirst("end_ns=".count)))
        )
    }
}
