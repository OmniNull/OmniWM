// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class StopWorkerLifecycleTests: XCTestCase {
    func testQuitRequestsDeferAndRegisterOnlyOneCompletion() async {
        let delegate = AppDelegate()
        let requested = expectation(description: "Restoration started after terminateLater reply")
        var completion: (@MainActor @Sendable () -> Void)?
        var replies = 0
        let first = delegate.deferTermination(stop: { completion = $0
            requested.fulfill()
        }, reply: { replies += 1 })
        let second = delegate.deferTermination(
            stop: { _ in XCTFail("Duplicate recovery") },
            reply: { XCTFail("Duplicate reply") }
        )
        XCTAssertEqual(first, .terminateLater)
        XCTAssertEqual(second, .terminateLater)
        XCTAssertEqual(replies, 0)
        await fulfillment(of: [requested], timeout: failureBound)
        completion?()
        XCTAssertEqual(replies, 1)
    }

    func testQuitDeadlineDoesNotReleaseReenableBarrierOrReplyTwice() async throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "StopDeadline")
        let contextValue = try await AppAXContextRegistry.getOrCreate(.current, pid: 696_205)
        let context = try XCTUnwrap(contextValue)
        let worker = try XCTUnwrap(context.axThread)
        let started = expectation(description: "Worker blocked in native call")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        worker.runInLoopAsync { _ in started.fulfill()
            release.wait()
        }
        await fulfillment(of: [started], timeout: failureBound)
        let quit = expectation(description: "Quit deadline")
        var replies = 0
        controller.setEnabled(false)
        controller.serviceLifecycleManager.stopRestoringWindows(forQuit: true) { replies += 1
            quit.fulfill()
        }
        await fulfillment(of: [quit], timeout: failureBound)
        XCTAssertEqual(controller.serviceLifecycleManager.userStopPhase, .tearingDown)
        XCTAssertFalse(controller.hasStartedServices)
        let exited = expectation(description: "Old worker exits")
        AppAXContextRegistry.workerLifetime.whenFinished { exited.fulfill() }
        release.signal()
        await fulfillment(of: [exited], timeout: failureBound)
        XCTAssertEqual(controller.serviceLifecycleManager.userStopPhase, .idle)
        XCTAssertEqual(replies, 1)
    }

    func testLifetimeWaitsForEveryOldWorkerAndIgnoresNewGeneration() {
        let lifetime = AppAXWorkerLifetime()
        lifetime.started(1)
        lifetime.started(2)
        var completed = 0
        lifetime.whenFinished { completed += 1 }
        lifetime.started(3)
        lifetime.finished(2)
        XCTAssertEqual(completed, 0)
        lifetime.finished(1)
        XCTAssertEqual(completed, 1)
        lifetime.finished(1)
        lifetime.finished(3)
        XCTAssertEqual(completed, 1)
    }

    func testRetiringContextRemainsInShutdownCompletionBarrier() async throws {
        let contextValue = try await AppAXContextRegistry.getOrCreate(.current, pid: 696_201)
        let context = try XCTUnwrap(contextValue)
        let worker = try XCTUnwrap(context.axThread)
        let started = expectation(description: "Native work started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        worker.runInLoopAsync { _ in started.fulfill()
            release.wait()
        }
        await fulfillment(of: [started], timeout: failureBound)
        context.destroy()
        XCTAssertNil(AppAXContextRegistry.contexts[context.pid])
        var finished = false
        let teardown = expectation(description: "Actual worker exit")
        AppAXContextRegistry.shutdownAll { finished = true
            teardown.fulfill()
        }
        XCTAssertFalse(finished)
        release.signal()
        await fulfillment(of: [teardown], timeout: failureBound)
        XCTAssertTrue(finished)
    }

    func testOrdinaryParkAndClosingWritesAreCancelledBeforeRestoration() async throws {
        let contextValue = try await AppAXContextRegistry.getOrCreate(.current, pid: 696_202)
        let context = try XCTUnwrap(contextValue)
        defer { context.destroy() }
        let worker = try XCTUnwrap(context.axThread)
        let started = expectation(description: "Frame write in progress")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let events = Mutex<[String]>([])
        let inFlight = worker.runInLoopAsync { _ in
            started.fulfill()
            release.wait()
            events.withLock { $0.append("in-flight-finished") }
        }
        context.frameDelivery.trackFrameJob(inFlight, batchId: UUID())
        await fulfillment(of: [started], timeout: failureBound)
        let parked = worker.runInLoopAsync { _ in events.withLock { $0.append("stale-park") } }
        let closing = worker.runInLoopAsync { _ in events.withLock { $0.append("stale-close") } }
        context.frameDelivery.trackParkFrameJob(parked)
        context.frameDelivery.trackClosingFrameJob(closing, batchId: UUID())
        context.prepareForStopRestoration()
        let token = WindowToken(pid: context.pid, windowId: 696_203)
        let target = StopWindowTarget(
            token: token,
            window: WindowAdmissionTestSupport.axRef(for: token),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            placement: nil
        )
        let restored = Task {
            await context.restoreForStop(target, deadline: ProcessInfo.processInfo.systemUptime + 5) { _ in
                StopWindowOperations(
                    setTimeout: { _ in true }, readMinimized: { false }, unminimize: { false },
                    readFrame: { CGRect(x: 2000, y: -200, width: 420, height: 300) },
                    writePosition: { frame, _ in
                        events.withLock { $0.append("restored") }
                        return AXFrameWriteResult(
                            observedFrame: frame,
                            writeOrder: .sizeThenPosition,
                            sizeError: .success,
                            positionError: .success,
                            failureReason: nil,
                            components: .position
                        )
                    }
                )
            }
        }
        release.signal()
        let result = await restored.value
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.frame?.size, CGSize(width: 420, height: 300))
        XCTAssertEqual(events.withLock { $0 }, ["in-flight-finished", "restored"])
    }

    func testDisableThenEnableWaitsForWorkerExitAndRepeatedQuitCoalesces() async throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "StopLifecycle")
        let contextValue = try await AppAXContextRegistry.getOrCreate(.current, pid: 696_204)
        let context = try XCTUnwrap(contextValue)
        let worker = try XCTUnwrap(context.axThread)
        let started = expectation(description: "Old worker held")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        worker.runInLoopAsync { _ in started.fulfill()
            release.wait()
        }
        await fulfillment(of: [started], timeout: failureBound)
        controller.setEnabled(false)
        XCTAssertFalse(controller.desiredEnabled)
        controller.setEnabled(true)
        XCTAssertTrue(controller.desiredEnabled)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.hasStartedServices)
        let lifecycle = controller.serviceLifecycleManager
        let quit = expectation(description: "Quit completes after old worker")
        var completions = 0
        lifecycle.stopRestoringWindows(forQuit: true) { completions += 1
            quit.fulfill()
        }
        lifecycle.stopRestoringWindows(forQuit: true)
        XCTAssertEqual(completions, 0)
        release.signal()
        await fulfillment(of: [quit], timeout: failureBound)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(lifecycle.userStopPhase, .idle)
        XCTAssertFalse(controller.hasStartedServices)
    }
}
