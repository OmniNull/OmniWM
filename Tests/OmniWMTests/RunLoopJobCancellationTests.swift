// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

private final class BodyRunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class RunLoopJobCancellationTests: XCTestCase {
    private var thread: Thread!

    override func setUp() {
        super.setUp()
        let thread = Thread {
            let port = NSMachPort()
            RunLoop.current.add(port, forMode: .default)
            CFRunLoopRun()
        }
        thread.name = "OmniWM-RunLoopJobTests"
        thread.start()
        self.thread = thread
    }

    override func tearDown() {
        thread.runInLoopAsync { _ in
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        thread = nil
        super.tearDown()
    }

    private func waitForMarker() {
        let marker = expectation(description: "marker job ran")
        thread.runInLoopAsync { _ in
            marker.fulfill()
        }
        wait(for: [marker], timeout: failureBound)
    }

    func testCancelBeforeRunLoopProcessesJobSkipsBody() {
        let counter = BodyRunCounter()
        let gate = DispatchSemaphore(value: 0)
        thread.runInLoopAsync { _ in
            gate.wait()
        }

        let job = thread.runInLoopAsync { _ in
            counter.increment()
        }
        job.cancel()
        gate.signal()

        waitForMarker()
        XCTAssertEqual(counter.value, 0)
        XCTAssertTrue(job.isCancelled)
    }

    func testBodyRunsExactlyOnceWithoutCancellation() {
        let counter = BodyRunCounter()
        let bodyRan = expectation(description: "body ran")
        let job = thread.runInLoopAsync { _ in
            counter.increment()
            bodyRan.fulfill()
        }

        wait(for: [bodyRan], timeout: failureBound)
        waitForMarker()
        XCTAssertEqual(counter.value, 1)
        XCTAssertFalse(job.isCancelled)
    }

    func testPrecancelledJobSkipsBodyWhenAutoCheckingCancellation() {
        let counter = BodyRunCounter()
        let job = RunLoopJob()
        job.cancel()

        thread.runInLoopAsync(job: job) { _ in
            counter.increment()
        }

        waitForMarker()
        XCTAssertEqual(counter.value, 0)
    }

    func testPrecancelledJobStillRunsBodyWithoutAutoCheck() {
        let counter = BodyRunCounter()
        let bodyRan = expectation(description: "body ran despite cancellation")
        let job = RunLoopJob()
        job.cancel()

        thread.runInLoopAsync(job: job, autoCheckCancelled: false) { job in
            counter.increment()
            XCTAssertTrue(job.isCancelled)
            bodyRan.fulfill()
        }

        wait(for: [bodyRan], timeout: failureBound)
        XCTAssertEqual(counter.value, 1)
    }

    func testCancelIsIdempotentAndCheckCancellationThrows() throws {
        let job = RunLoopJob()
        XCTAssertFalse(job.isCancelled)
        XCTAssertNoThrow(try job.checkCancellation())

        job.schedule { _ in }

        job.cancel()
        job.cancel()

        XCTAssertNil(job.takeScheduledBody())
        XCTAssertTrue(job.isCancelled)
        XCTAssertThrowsError(try job.checkCancellation()) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }
}
