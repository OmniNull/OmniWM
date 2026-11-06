// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Dispatch
import Foundation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class WindowFocusDispatcherTests: XCTestCase {
    func testSubmissionsRunInOrderAndBarriersWaitOnlyForEarlierSubmissions() async {
        let order = Mutex<[UInt32]>([])
        let firstGate = DispatchSemaphore(value: 0)
        let thirdGate = DispatchSemaphore(value: 0)
        let dispatcher = WindowFocusDispatcher(label: "OmniWMTests-FocusOrder") { _, windowId in
            switch windowId {
            case 1: firstGate.wait()
            case 3: thirdGate.wait()
            default: break
            }
            order.withLock { $0.append(windowId) }
        }
        var events: [String] = []
        dispatcher.afterSubmitted { events.append("idle") }
        XCTAssertEqual(events, ["idle"])

        dispatcher.submit(pid: 1, windowId: 1)
        dispatcher.submit(pid: 2, windowId: 2)
        let afterSecond = expectation(description: "Barrier after the second submission")
        dispatcher.afterSubmitted {
            events.append("after-2")
            afterSecond.fulfill()
        }
        dispatcher.submit(pid: 3, windowId: 3)
        let afterThird = expectation(description: "Barrier after the third submission")
        dispatcher.afterSubmitted {
            events.append("after-3")
            afterThird.fulfill()
        }
        XCTAssertEqual(events, ["idle"])

        firstGate.signal()
        await fulfillment(of: [afterSecond], timeout: failureBound)

        XCTAssertEqual(order.withLock { $0 }, [1, 2])
        XCTAssertEqual(events, ["idle", "after-2"])

        thirdGate.signal()
        await fulfillment(of: [afterThird], timeout: failureBound)

        XCTAssertEqual(order.withLock { $0 }, [1, 2, 3])
        XCTAssertEqual(events, ["idle", "after-2", "after-3"])
    }

    func testWaitForSubmittedFollowsEarlierFocusWhileMainIsBlocked() {
        let order = Mutex<[String]>([])
        let workerStarted = DispatchSemaphore(value: 0)
        let workerFinished = DispatchSemaphore(value: 0)
        let focusGate = DispatchSemaphore(value: 0)
        let dispatcher = WindowFocusDispatcher(label: "OmniWMTests-FocusWait") { _, _ in
            focusGate.wait()
            order.withLock { $0.append("focus") }
        }
        dispatcher.submit(pid: 1, windowId: 1)

        DispatchQueue.global().async {
            workerStarted.signal()
            dispatcher.waitForSubmitted()
            order.withLock { $0.append("raise") }
            workerFinished.signal()
        }
        workerStarted.wait()
        focusGate.signal()
        workerFinished.wait()

        XCTAssertEqual(order.withLock { $0 }, ["focus", "raise"])
    }

    func testRetryRaiseTraceRecordsOnlyWhenPostedDuringCaptureAndOrdersPhases() throws {
        let recorder = WindowFocusDispatchTrace.retryRaise
        recorder.beginCapture()
        defer {
            recorder.endCapture()
            recorder.releaseStorage()
        }
        var steps: [String] = []
        WindowFocusDispatchTrace.traceRetryRaise(pid: 7, windowId: 70, postedNs: 0) { waited in
            waited()
            steps.append("untraced")
            return true
        }
        XCTAssertEqual(recorder.dump(), "none")

        let postedNs = DispatchTime.now().uptimeNanoseconds
        WindowFocusDispatchTrace.traceRetryRaise(pid: 7, windowId: 71, postedNs: postedNs) { waited in
            steps.append("wait")
            waited()
            steps.append("raise")
            return false
        }

        XCTAssertEqual(steps, ["untraced", "wait", "raise"])
        let line = recorder.dump()
        XCTAssertTrue(line.hasPrefix("scope=worker-retry-raise"))
        XCTAssertTrue(line.contains(" pid=7 win=71 posted_ns=\(postedNs) "))
        XCTAssertTrue(line.hasSuffix(" raised=false"))
        let fields = Dictionary(uniqueKeysWithValues: line.split(separator: " ").compactMap { part -> (
            String,
            String
        )? in
            let pair = part.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        })
        let started = try XCTUnwrap(fields["start_ns"].flatMap { UInt64($0) })
        let waited = try XCTUnwrap(fields["waited_ns"].flatMap { UInt64($0) })
        let ended = try XCTUnwrap(fields["end_ns"].flatMap { UInt64($0) })
        XCTAssertTrue(postedNs <= started && started <= waited && waited <= ended)
    }

    func testDrainWaitsForQueuedFocusBeforeSynchronousWork() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = Mutex(false)
        let dispatcher = WindowFocusDispatcher(label: "OmniWMTests-FocusDrain") { _, _ in
            started.signal()
            release.wait()
            finished.withLock { $0 = true }
        }
        dispatcher.drain()

        dispatcher.submit(pid: 1, windowId: 1)
        DispatchQueue.global().async {
            started.wait()
            release.signal()
        }
        dispatcher.drain()

        XCTAssertTrue(finished.withLock { $0 })
    }
}
