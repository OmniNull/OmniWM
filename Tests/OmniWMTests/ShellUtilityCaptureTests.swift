// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

final class ShellUtilityCaptureTests: XCTestCase {
    private let owner = ShellServiceOwner(generation: 70, owner: 1, epoch: 2)

    func testCaptureStorageIsBounded() {
        XCTAssertLessThanOrEqual(MemoryLayout<ShellProviderLineFramer.Capture>.stride, 128)
        XCTAssertLessThanOrEqual(MemoryLayout<ShellProvider.Capture>.stride, 128)
        XCTAssertLessThanOrEqual(MemoryLayout<ShellProviderInbox.Capture>.stride, 128)
        XCTAssertLessThanOrEqual(MemoryLayout<ShellServiceLedger.Capture>.stride, 128)
        XCTAssertLessThanOrEqual(MemoryLayout<ShellResourceInbox.Capture>.stride, 128)
        XCTAssertLessThanOrEqual(MemoryLayout<ShellHTTPService.Capture>.stride, 128)
        XCTAssertLessThanOrEqual(MemoryLayout<ShellResourceThumbnails.Capture>.stride, 128)
        XCTAssertLessThanOrEqual(MemoryLayout<ShellThumbnailCache.Capture>.stride, 128)
    }

    func testFramingCaptureCountsActualLinesAndNotReceiverFailuresAcrossReset() throws {
        var framer = ShellProviderLineFramer()
        let line = Data("[\"state\",\"value\",1]\n".utf8)
        try line.withUnsafeBytes { try framer.consume($0) { _ in } }
        XCTAssertNil(framer.captureEnd(1))
        framer.captureBegin(1)
        try line.withUnsafeBytes { try framer.consume($0) { _ in } }
        framer.captureBegin(1)
        XCTAssertNil(framer.captureEnd(2))
        XCTAssertThrowsError(try line.withUnsafeBytes {
            try framer.consume($0) { _ in throw ShellProviderProtocol.Failure(message: "receiver rejected") }
        })
        framer.reset()
        XCTAssertThrowsError(try Data("invalid\n".utf8).withUnsafeBytes {
            try framer.consume($0) { _ in XCTFail("invalid line delivered") }
        })
        framer.reset()
        try Data("partial".utf8).withUnsafeBytes { try framer.consume($0) { _ in XCTFail() } }
        XCTAssertThrowsError(try framer.finish())
        let capture = try XCTUnwrap(framer.captureEnd(1))
        XCTAssertEqual(capture.completedLines, 3)
        XCTAssertEqual(capture.framingFailures, 2)
        XCTAssertNil(framer.captureEnd(1))
        framer.reset()
        try line.withUnsafeBytes { try framer.consume($0) { _ in } }
        framer.captureBegin(2)
        XCTAssertEqual(framer.captureEnd(2)?.completedLines, 0)
    }

    func testProviderSignalsCountQueuedWakesRatherThanActiveLatch() throws {
        let signals = ShellProvider.Signals()
        let identity = ShellProviderIdentity(owner: owner, incarnation: 1)
        let wakes = Mutex(0)
        signals.attach { wakes.withLock { $0 += 1 } }
        signals.arm(identity)
        signals.captureBegin(1)
        for _ in 0 ..< 1000 { signals.post(.output, identity: identity) }
        XCTAssertEqual(wakes.withLock { $0 }, 1)
        XCTAssertEqual(signals.take()?.1, .output)
        signals.post(.diagnostic, identity: identity)
        XCTAssertEqual(wakes.withLock { $0 }, 1)
        signals.finish()
        XCTAssertEqual(wakes.withLock { $0 }, 2)
        XCTAssertEqual(signals.take()?.1, .diagnostic)
        signals.finish()
        let capture = try XCTUnwrap(signals.captureEnd(1))
        XCTAssertEqual(capture.emitted, 2)
        XCTAssertEqual(capture.consumed, 2)
        XCTAssertEqual(capture.pending, 0)
        XCTAssertEqual(capture.peak, 1)
        XCTAssertNil(signals.captureEnd(1))
    }

    func testProviderFloodCountsIngressAndOnlyConsumedNonremovedTopics() throws {
        let inbox = ShellProviderInbox()
        let identity = ShellProviderIdentity(owner: owner, incarnation: 1)
        XCTAssertTrue(inbox.activate(identity))
        _ = inbox.takeBatch(now: 0)
        _ = inbox.finishBatch(now: 0)
        let wakes = Mutex(0)
        inbox.attachWake { wakes.withLock { $0 += 1 } }
        inbox.captureBegin(8)
        for value in 0 ..< 50_000 {
            XCTAssertEqual(
                inbox.post(.state(topic: "count", value: Data(String(value).utf8)), from: identity),
                .accepted
            )
        }
        XCTAssertEqual(wakes.withLock { $0 }, 1)
        inbox.captureWakeConsumed()
        XCTAssertEqual(
            inbox.takeBatch(now: 1).first?.snapshot?.topics,
            [.init(name: "count", value: Data("49999".utf8))]
        )
        XCTAssertEqual(inbox.finishBatch(now: 1), .idle)
        XCTAssertEqual(inbox.post(.state(topic: "count", value: Data("null".utf8)), from: identity), .accepted)
        XCTAssertEqual(inbox.takeState(identity, now: 2)?.topics, [.init(name: "count", value: nil)])
        inbox.captureWakeConsumed()
        XCTAssertTrue(inbox.takeBatch(now: 2).isEmpty)
        _ = inbox.finishBatch(now: 2)
        let capture = try XCTUnwrap(inbox.captureEnd(8))
        XCTAssertEqual(capture.receivedStates, 50_001)
        XCTAssertEqual(capture.coalescedStates, 49_999)
        XCTAssertEqual(capture.consumedSnapshots, 2)
        XCTAssertEqual(capture.consumedTopics, 1)
        XCTAssertEqual(capture.wakes.emitted, 2)
        XCTAssertEqual(capture.wakes.pending, 0)
        XCTAssertEqual(capture.wakes.peak, 1)
    }

    func testProviderActionAndEventPeaksRemainSeparate() throws {
        let inbox = ShellProviderInbox()
        let identity = ShellProviderIdentity(owner: owner, incarnation: 1)
        XCTAssertTrue(inbox.activate(identity))
        _ = inbox.takeBatch(now: 0)
        _ = inbox.finishBatch(now: 0)
        inbox.captureBegin(4)
        for request in 1 ... 20 {
            XCTAssertTrue(inbox.register(.init(owner: owner, request: UInt64(request)), identity: identity))
            XCTAssertEqual(inbox.post(.event(name: "event", value: Data("null".utf8)), from: identity), .accepted)
        }
        XCTAssertEqual(inbox.takeBatch(now: 1).count, 16)
        for request in 1 ... 20 { inbox.cancel(.init(owner: owner, request: UInt64(request))) }
        let capture = try XCTUnwrap(inbox.captureEnd(4))
        XCTAssertEqual(capture.actionsBegin, 0)
        XCTAssertEqual(capture.actionsPeak, 20)
        XCTAssertEqual(capture.actionsEnd, 0)
        XCTAssertEqual(capture.eventsPeak, 20)
        XCTAssertEqual(capture.eventsEnd, 4)
        XCTAssertEqual(capture.wakes.emitted, 0)
    }

    func testLedgerSnapshotSeparatesBaselineDepthFromBoundedBatchWakes() throws {
        let ledger = ShellServiceLedger(generation: owner.generation)
        XCTAssertTrue(ledger.register(.init(owner: owner, request: 1)))
        ledger.captureBegin(5)
        let wakes = Mutex(0)
        ledger.attachWake { wakes.withLock { $0 += 1 } }
        for request in 2 ... 20 { XCTAssertTrue(ledger.register(.init(owner: owner, request: UInt64(request)))) }
        for request in 1 ... 20 {
            XCTAssertTrue(ledger.complete(.init(id: .init(owner: owner, request: UInt64(request)), payload: [0])))
        }
        ledger.captureBegin(5)
        XCTAssertNil(ledger.captureEnd(6))
        ledger.captureWakeConsumed()
        XCTAssertEqual(ledger.takeBatch().count, 16)
        XCTAssertTrue(ledger.finishBatch())
        ledger.captureWakeConsumed()
        XCTAssertEqual(ledger.takeBatch().count, 4)
        XCTAssertFalse(ledger.finishBatch())
        let capture = try XCTUnwrap(ledger.captureEnd(5))
        XCTAssertEqual(capture.activeBegin, 1)
        XCTAssertEqual(capture.activePeak, 20)
        XCTAssertEqual(capture.activeEnd, 0)
        XCTAssertEqual(capture.completionsPeak, 20)
        XCTAssertEqual(capture.completionsEnd, 0)
        XCTAssertEqual(capture.wakes.emitted, 2)
        XCTAssertEqual(capture.wakes.consumed, 2)
        XCTAssertEqual(capture.wakes.pending, 0)
        XCTAssertEqual(capture.wakes.peak, 1)
        XCTAssertEqual(wakes.withLock { $0 }, 2)
        XCTAssertNil(ledger.captureEnd(5))
    }

    func testResourceWakeCoalescesAndRetainsPendingUntilActualMailboxConsumption() throws {
        let inbox = ShellResourceInbox()
        let wakes = Mutex(0)
        inbox.attach(owner)
        inbox.attachWake { wakes.withLock { $0 += 1 } }
        inbox.captureBegin(2)
        for _ in 0 ..< 100 { inbox.changed(owner) }
        XCTAssertEqual(wakes.withLock { $0 }, 1)
        inbox.captureWakeConsumed()
        XCTAssertEqual(inbox.take(), [owner])
        inbox.changed(owner)
        inbox.close()
        let capture = try XCTUnwrap(inbox.captureEnd(2))
        XCTAssertEqual(capture.changedPeak, 1)
        XCTAssertEqual(capture.changedEnd, 0)
        XCTAssertEqual(capture.wakes.emitted, 2)
        XCTAssertEqual(capture.wakes.consumed, 1)
        XCTAssertEqual(capture.wakes.pending, 1)
        XCTAssertEqual(capture.wakes.peak, 1)
    }
}
