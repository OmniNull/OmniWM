// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Dispatch
@testable import OmniWM
import XCTest

@MainActor
final class EventIntakeTraceTests: XCTestCase {
    private final class Sink: EventIntakeSink {
        var received: [StampedIntakeEvent] = []

        func handleIntakeEvent(_ stamped: StampedIntakeEvent) {
            received.append(stamped)
        }
    }

    func testQueueWaitAndHandlerWorkAreReportedSeparately() {
        let trace = EventIntakeTrace.shared
        trace.beginCapture()
        defer { trace.endCapture() }
        trace.record(EventIntakeTrace.Record(
            sequence: 7,
            enqueuedNs: 1_000_000,
            startedNs: 4_000_000,
            endedNs: 12_000_000,
            identity: .init(kind: "hotkey")
        ))

        let dump = trace.dump()
        XCTAssertTrue(dump.contains("seq=7 kind=hotkey"), dump)
        XCTAssertTrue(dump.contains("start_ns=4000000 end_ns=12000000"), dump)
        XCTAssertTrue(dump.contains("queue_us=3000.0 handler_us=8000.0"), dump)
    }

    func testCapturePreservesCoalescingAndOriginalEnqueueTime() throws {
        let trace = EventIntakeTrace.shared
        trace.endCapture()
        trace.releaseStorage()
        let intake = EventIntake()
        let sink = Sink()
        intake.open(sink: sink)
        defer {
            intake.close()
            trace.endCapture()
        }

        intake.enqueue(.cgs(.frameChanged(windowId: 10)))
        intake.drainNow()
        XCTAssertNil(sink.received.first?.enqueuedUptimeNs)
        XCTAssertEqual(trace.dump(), "none")

        trace.beginCapture()
        intake.enqueue(.mouseMoved(location: .zero, modifiersRawValue: 0, windowIdUnderPointer: 10))
        let afterFirstEnqueue = DispatchTime.now().uptimeNanoseconds
        intake.enqueue(.mouseMoved(location: CGPoint(x: 2, y: 3), modifiersRawValue: 0, windowIdUnderPointer: 20))
        intake.drainNow()

        XCTAssertEqual(sink.received.count, 2)
        let event = try XCTUnwrap(sink.received.last)
        XCTAssertLessThanOrEqual(try XCTUnwrap(event.enqueuedUptimeNs), afterFirstEnqueue)
        guard case let .mouseMoved(location, _, windowId) = event.event else {
            return XCTFail("Expected coalesced mouse event")
        }
        XCTAssertEqual(location, CGPoint(x: 2, y: 3))
        XCTAssertEqual(windowId, 20)
        let dump = trace.dump()
        XCTAssertEqual(dump.split(separator: "\n").count, 1)
        XCTAssertTrue(dump.contains("seq=2 kind=mouse-move"), dump)
        XCTAssertFalse(dump.contains("queue_us=unknown"), dump)
    }

    func testCaptureBeginningAfterEnqueueDoesNotInventQueueLatency() {
        let trace = EventIntakeTrace.shared
        trace.endCapture()
        let intake = EventIntake()
        let sink = Sink()
        intake.open(sink: sink)
        defer {
            intake.close()
            trace.endCapture()
        }
        intake.enqueue(.cgs(.created(windowId: 99, spaceId: 1)))
        trace.beginCapture()
        intake.drainNow()

        let dump = trace.dump()
        XCTAssertTrue(dump.contains("kind=cgs.created pid=0 win=99"), dump)
        XCTAssertTrue(dump.contains("enqueued_ns=unknown"), dump)
        XCTAssertTrue(dump.contains("queue_us=unknown"), dump)
    }

    func testSameProcessWindowsRemainDistinctInDeliveredEventTiming() {
        let trace = EventIntakeTrace.shared
        trace.beginCapture()
        let intake = EventIntake()
        let sink = Sink()
        intake.open(sink: sink)
        defer {
            intake.close()
            trace.endCapture()
        }
        for windowId in [101, 102] {
            intake.enqueue(.axWindow(.windowMiniaturized(
                pid: 81,
                axRef: AXWindowRef(element: AXUIElementCreateApplication(81), windowId: windowId),
                callbackGeneration: nil
            )))
        }
        intake.drainNow()

        let dump = trace.dump()
        XCTAssertTrue(dump.contains("seq=1 kind=ax.minimized pid=81 win=101"), dump)
        XCTAssertTrue(dump.contains("seq=2 kind=ax.minimized pid=81 win=102"), dump)
    }
}
