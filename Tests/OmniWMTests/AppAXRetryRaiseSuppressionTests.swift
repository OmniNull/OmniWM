// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class AppAXRetryRaiseSuppressionTests: XCTestCase {
    func testLayoutHiddenRaiseSurvivesFrameSuppressionButNotNativeSuppression() {
        for allowsLayoutHiddenWindow in [false, true] {
            withContext { context, window in
                let job = RunLoopJob()
                XCTAssertTrue(context.enqueueRetryRaise(
                    window, job: job, awaitingSubmittedFocus: {},
                    allowsLayoutHiddenWindow: allowsLayoutHiddenWindow, completion: {}
                ))

                context.suppressFrameWrites(for: [window.windowId])

                XCTAssertEqual(job.isCancelled, !allowsLayoutHiddenWindow)
                XCTAssertTrue(context.frameDelivery.retryRaiseSuppression.contains(window.windowId))
                context.setWindowNativeSuppressed(true, for: window.windowId)
                XCTAssertTrue(job.isCancelled)
            }
        }
    }

    func testLayoutHiddenRaiseStillCancelsWhenApplicationHides() {
        withContext { context, window in
            let job = RunLoopJob()
            XCTAssertTrue(context.enqueueRetryRaise(
                window, job: job, awaitingSubmittedFocus: {},
                allowsLayoutHiddenWindow: true, completion: {}
            ))
            context.suppressFrameWrites(for: [window.windowId])
            XCTAssertFalse(job.isCancelled)

            context.setMacOSAppHidden(true, for: [window.windowId])

            XCTAssertTrue(job.isCancelled)
            XCTAssertTrue(context.frameDelivery.retryRaiseSuppression.isHardSuppressed(for: window.windowId))
        }
    }

    func testFrameWritesReachTheAppWorkerWhileRetryRaiseIsBlocked() async throws {
        let (worker, window) = try await makeBoundContext(pid: 831_010, windowId: 831_110)
        defer { worker.destroy() }
        let started = expectation(description: "Retry raise entered the AX call")
        let finished = expectation(description: "Retry raise completed")
        let submittedFocus = Mutex(false)
        let releaseRaise = DispatchSemaphore(value: 0)
        defer { releaseRaise.signal() }
        XCTAssertTrue(worker.enqueueRetryRaise(
            window,
            job: RunLoopJob(),
            awaitingSubmittedFocus: { submittedFocus.withLock { $0 = true } },
            raiseWindow: { element in
                XCTAssertTrue(submittedFocus.withLock { $0 })
                XCTAssertTrue(CFEqual(element, window.element))
                started.fulfill()
                releaseRaise.wait()
                return true
            },
            completion: { finished.fulfill() }
        ))
        await fulfillment(of: [started], timeout: failureBound)

        for frameIndex in 1 ... 2 {
            let frame = AXFrameApplicationRequest(
                requestId: AXFrameRequestId(frameIndex),
                pid: worker.pid,
                windowId: window.windowId,
                expectedWindow: window,
                frame: CGRect(x: 20 * frameIndex, y: 10, width: 640, height: 480),
                currentFrameHint: nil
            )
            let applied = expectation(description: "Frame \(frameIndex) ran before the raise completed")
            worker.setFramesBatch([frame]) { results in
                XCTAssertEqual(results.map(\.requestId), [frame.requestId])
                XCTAssertTrue(results.first?.didAttemptWrite == true)
                applied.fulfill()
            }
            await fulfillment(of: [applied], timeout: failureBound)
        }

        releaseRaise.signal()
        await fulfillment(of: [finished], timeout: failureBound)
    }

    func testRetryRaiseCancelsWhileWaitingForSubmittedFocus() async throws {
        let (worker, window) = try await makeBoundContext(pid: 831_007, windowId: 831_107)
        defer { worker.destroy() }
        let job = RunLoopJob()
        let finished = expectation(description: "Cancelled retry raise completed")

        XCTAssertTrue(worker.enqueueRetryRaise(
            window,
            job: job,
            awaitingSubmittedFocus: { job.cancel() },
            raiseWindow: { _ in
                XCTFail("A superseded focus request tried to raise its window")
                return false
            },
            completion: { finished.fulfill() }
        ))
        await fulfillment(of: [finished], timeout: failureBound)
        XCTAssertTrue(job.isCancelled)
    }

    func testEnumerationInvalidatesQueuedRaiseWhenBindingChanges() async throws {
        let (worker, window) = try await makeBoundContext(pid: 831_011, windowId: 831_111)
        defer { worker.destroy() }
        let thread = try XCTUnwrap(worker.axThread)
        let replacement = AXWindowRef(element: AXUIElementCreateApplication(worker.pid + 1), windowId: window.windowId)
        let equivalent = AXWindowRef(element: AXUIElementCreateApplication(worker.pid), windowId: window.windowId)
        let cases: [(name: String, enumeratedWindow: AXWindowRef?, shouldRaise: Bool)] = [
            ("replaced", replacement, false),
            ("removed", nil, false),
            ("unchanged", equivalent, true)
        ]

        for scenario in cases {
            let windows = try await thread.runInLoop(timeout: .seconds(failureBound)) { _ in
                ThreadGuardedValue([window.windowId: window.element])
            }
            defer { thread.runInLoopAsync { _ in windows.destroy() } }
            let epoch = LockedGenerationEpoch()
            let generation = epoch.current()
            let job = RunLoopJob()
            let binding = AppAXRetryRaiseBinding()
            let queue = DispatchQueue(label: "OmniWMTests-RetryRaise-\(scenario.name)")
            let paused = expectation(description: "Raise queue paused for \(scenario.name) binding")
            let finished = expectation(description: "Retry raise completed for \(scenario.name) binding")
            let resumeRaise = DispatchSemaphore(value: 0)
            defer { resumeRaise.signal() }
            let didRaise = Mutex(false)
            AppAXRetryRaiseOperation(
                window: window, pid: worker.pid, job: job, binding: binding, suppression: LockedWindowIdSet(),
                allowsLayoutHiddenWindow: false,
                awaitingSubmittedFocus: {
                    queue.async {
                        paused.fulfill()
                        resumeRaise.wait()
                    }
                },
                raiseWindow: { _ in
                    didRaise.withLock { $0 = true }
                    return true
                }
            ).enqueue(on: queue, appThread: thread, windows: windows) {
                finished.fulfill()
            }
            guard await XCTWaiter.fulfillment(of: [paused], timeout: failureBound) == .completed else {
                XCTFail("Retry raise never reached the app thread")
                return
            }
            let enumeratedWindow = scenario.enumeratedWindow
            let committed = try await thread.runInLoop(timeout: .seconds(failureBound)) { _ in
                AppAXContext.replaceEnumeratedWindowCache(
                    with: enumeratedWindow.map { [window.windowId: $0.element] } ?? [:],
                    windows: windows, bindingGeneration: generation,
                    windowBindingEpoch: epoch, retryRaiseBinding: binding
                )
            }
            XCTAssertTrue(committed)
            resumeRaise.signal()
            await fulfillment(of: [finished], timeout: failureBound)
            XCTAssertEqual(didRaise.withLock { $0 }, scenario.shouldRaise, scenario.name)
            XCTAssertEqual(job.isCancelled, !scenario.shouldRaise, scenario.name)
        }
    }

    private func makeBoundContext(pid: pid_t, windowId: Int) async throws -> (AppAXContext, AXWindowRef) {
        let context = try await AppAXContextRegistry.getOrCreate(.current, pid: pid)
        let worker = try XCTUnwrap(context)
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let bound = expectation(description: "Window bound on the app AX thread")
        worker.bindWindows([windowId: window]) { _ in bound.fulfill() }
        await fulfillment(of: [bound], timeout: failureBound)
        return (worker, window)
    }

    private func withContext(_ body: (AppAXContext, AXWindowRef) -> Void) {
        let pid: pid_t = 831_009
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 831_109)
        $appThreadToken.withValue(AppThreadToken(pid: pid)) {
            let app = ThreadGuardedValue(window.element)
            let windows = ThreadGuardedValue([window.windowId: window.element])
            let observer = ThreadGuardedValue<AXObserver?>(nil)
            let focusedObserver = ThreadGuardedValue<AXObserver?>(nil)
            let subscriptions = ThreadGuardedValue<[Int: AppAXWindowSubscription]>([:])
            let removals = ThreadGuardedValue<[AppAXPendingNotificationRemoval]>([])
            let context = AppAXContext(
                .current, pid: pid, app, windows, observer, focusedObserver, subscriptions, removals,
                nil, nil, UInt64(pid), Thread.current
            )
            defer {
                context.prepareForStopRestoration()
                AXWriteMetrics.shared.retire(context.writeMetricsToken)
                app.destroy()
                windows.destroy()
                observer.destroy()
                focusedObserver.destroy()
                subscriptions.destroy()
                removals.destroy()
            }
            body(context, window)
        }
    }
}
