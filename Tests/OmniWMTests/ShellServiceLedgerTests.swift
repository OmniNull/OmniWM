// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class ShellServiceLedgerTests: XCTestCase {
    func testStartupCompletionsWakeOnceAndDrainInBoundedOrder() {
        let ledger = ShellServiceLedger(generation: 1)
        let wakes = Mutex(0)
        for request in 1 ... 20 {
            let id = id(UInt64(request))
            XCTAssertTrue(ledger.register(id))
            XCTAssertTrue(ledger.complete(ShellServiceCompletion(id: id, payload: [UInt8(request)])))
        }
        ledger.attachWake { wakes.withLock { $0 += 1 } }
        XCTAssertEqual(wakes.withLock { $0 }, 1)
        XCTAssertEqual(ledger.takeBatch(limit: 100).map(\.id.request), Array(1 ... 16).map(UInt64.init))
        XCTAssertTrue(ledger.finishBatch())
        XCTAssertEqual(wakes.withLock { $0 }, 2)
        XCTAssertEqual(ledger.takeBatch().map(\.id.request), [17, 18, 19, 20])
        XCTAssertFalse(ledger.finishBatch())
        XCTAssertEqual(ledger.activeCount, 0)
        XCTAssertTrue(ledger.register(id(21)))
        ledger.complete(ShellServiceCompletion(id: id(21), payload: []))
        XCTAssertEqual(wakes.withLock { $0 }, 3)
        ledger.close()
    }

    func testCompletionWhileBatchRunsSchedulesOnlyOneFollowOnWake() {
        let ledger = ShellServiceLedger(generation: 1)
        let wakes = Mutex(0)
        ledger.attachWake { wakes.withLock { $0 += 1 } }
        XCTAssertTrue(ledger.register(id(1)))
        ledger.complete(ShellServiceCompletion(id: id(1), payload: []))
        XCTAssertEqual(ledger.takeBatch().count, 1)
        XCTAssertTrue(ledger.register(id(2)))
        ledger.complete(ShellServiceCompletion(id: id(2), payload: []))
        XCTAssertTrue(ledger.finishBatch())
        XCTAssertEqual(wakes.withLock { $0 }, 2)
        XCTAssertEqual(ledger.takeBatch().map(\.id.request), [2])
        XCTAssertFalse(ledger.finishBatch())
    }

    func testCancellationDropsQueuedAndLateCompletionsByFullOwnerToken() {
        let ledger = ShellServiceLedger(generation: 1)
        let cancellations = Mutex(0)
        let old = id(1)
        XCTAssertTrue(ledger.register(old) { cancellations.withLock { $0 += 1 } })
        ledger.complete(ShellServiceCompletion(id: old, payload: []))
        ledger.cancel(owner: old.owner)
        XCTAssertEqual(cancellations.withLock { $0 }, 1)
        XCTAssertFalse(ledger.complete(ShellServiceCompletion(id: old, payload: [])))
        XCTAssertTrue(ledger.takeBatch().isEmpty)
        XCTAssertFalse(ledger.register(id(2, generation: 0)))
        let replacement = id(3, epoch: 2)
        XCTAssertTrue(ledger.register(replacement))
        ledger.cancel(owner: old.owner)
        XCTAssertTrue(ledger.complete(ShellServiceCompletion(id: replacement, payload: [])))
        XCTAssertEqual(ledger.takeBatch().map(\.id), [replacement])
    }

    func testNativeTrackingCannotExceedReservedCapacityOrRetainCancelledEntries() {
        let ledger = ShellServiceLedger(generation: 1)
        for request in 1 ... ShellServiceLedger.capacity {
            XCTAssertTrue(ledger.register(id(UInt64(request))))
        }
        XCTAssertFalse(ledger.register(id(257)))
        ledger.cancel(id(1))
        XCTAssertTrue(ledger.register(id(257)))
        for request in 2 ... 257 {
            let service = id(UInt64(request))
            XCTAssertTrue(ledger.complete(ShellServiceCompletion(id: service, payload: [])))
            XCTAssertFalse(ledger.complete(ShellServiceCompletion(id: service, payload: [])))
            ledger.cancel(service)
        }
        XCTAssertEqual(ledger.activeCount, 0)
        XCTAssertEqual(ledger.pendingCount, 0)
        ledger.close()
        XCTAssertFalse(ledger.register(id(258)))
    }

    func testNativeCancellationRunsOnceAfterDeliveryOrClose() {
        let ledger = ShellServiceLedger(generation: 1)
        let cancellations = Mutex(0)
        ledger.register(id(1)) { cancellations.withLock { $0 += 1 } }
        ledger.complete(ShellServiceCompletion(id: id(1), payload: []))
        _ = ledger.takeBatch()
        ledger.cancel(id(1))
        ledger.register(id(2)) { cancellations.withLock { $0 += 1 } }
        ledger.close()
        ledger.close()
        XCTAssertEqual(cancellations.withLock { $0 }, 2)
    }

    func testOneShotTimerPostsExactlyOneCompletion() async {
        let ledger = ShellServiceLedger(generation: 1)
        let fired = expectation(description: "timer completion")
        let queue = DispatchSerialQueue(label: "shell.timer.test")
        ledger.attachWake { fired.fulfill() }
        XCTAssertTrue(ledger.startTimer(id(1), seconds: 0.01, queue: queue))
        await fulfillment(of: [fired], timeout: 2)
        let batch = ledger.takeBatch()
        XCTAssertEqual(batch.map(\.id.request), [1])
        XCTAssertEqual(batch.first?.payload, [0])
        XCTAssertFalse(ledger.finishBatch())
        XCTAssertFalse(ledger.complete(ShellServiceCompletion(id: id(1), payload: [])))
        ledger.close()
    }

    func testCancelledAndInvalidTimersLeaveNoNativeOperation() {
        let ledger = ShellServiceLedger(generation: 1)
        let queue = DispatchSerialQueue(label: "shell.timer.cancel.test")
        XCTAssertFalse(ledger.startTimer(id(1), seconds: 0.001, queue: queue))
        XCTAssertFalse(ledger.startTimer(id(1), seconds: .infinity, queue: queue))
        XCTAssertTrue(ledger.startTimer(id(1), seconds: 3600, queue: queue))
        ledger.cancel(id(1))
        XCTAssertEqual(ledger.activeCount, 0)
        XCTAssertFalse(ledger.complete(ShellServiceCompletion(id: id(1), payload: [])))
    }

    private func id(_ request: UInt64, generation: UInt64 = 1, epoch: UInt32 = 1) -> ShellServiceID {
        ShellServiceID(owner: ShellServiceOwner(generation: generation, owner: 0, epoch: epoch), request: request)
    }
}
