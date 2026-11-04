// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class AsyncRetryRaiseTests: XCTestCase {
    private enum WorkerScenario: CaseIterable {
        case cancelled, frameSuppressed, appSuppressed, missing, replaced, accepted
    }

    func testRetirementAndLifecycleInvalidateQueuedRetry() throws {
        for transition in 0 ..< 7 {
            let ledger = IntentLedger()
            let token = WindowToken(pid: 831_001, windowId: 831_101)
            let request = ledger.beginManagedRequest(token: token, workspaceId: .init())
            ledger.enableDeferredRetryRaise(for: request)
            let job = try XCTUnwrap(ledger.beginDeferredRetryRaise(for: request))
            switch transition {
            case 0: _ = ledger.confirm(id: request.requestId)
            case 1: _ = ledger.cancel(id: request.requestId)
            case 2: _ = ledger.markExpired(id: request.requestId)
            case 3: _ = ledger.supersede(id: request.requestId)
            case 4: ledger.reset()
            case 5: ledger.discardPendingFocus(token)
            default:
                _ = ledger.beginManagedRequest(
                    token: WindowToken(pid: token.pid, windowId: token.windowId + 1), workspaceId: request.workspaceId
                )
            }
            XCTAssertTrue(job.isCancelled, "transition=\(transition)")
            XCTAssertNil(ledger.completeDeferredRetryRaise(job: job))
        }
    }

    func testRequiredRaiseSurvivesFocusConfirmationAndCompletesWithoutRetryingFocus() throws {
        let ledger = IntentLedger()
        let token = WindowToken(pid: 831_008, windowId: 831_108)
        let request = ledger.beginManagedRequest(token: token, workspaceId: .init())
        ledger.enableDeferredRetryRaise(for: request, required: true)
        let job = try XCTUnwrap(ledger.beginDeferredRetryRaise(for: request))

        XCTAssertNotNil(ledger.confirmManagedRequest(token: token, source: .focusedWindowChanged))

        XCTAssertNil(ledger.activeManagedRequest)
        XCTAssertFalse(job.isCancelled)
        XCTAssertTrue(ledger.defersRetryRaise(for: request))
        XCTAssertNil(ledger.beginDeferredRetryRaise(for: request))
        XCTAssertNil(ledger.completeDeferredRetryRaise(job: job))
        XCTAssertFalse(ledger.defersRetryRaise(for: request))
        XCTAssertNil(ledger.beginDeferredRetryRaise(for: request))
        XCTAssertNil(ledger.completeDeferredRetryRaise(job: job))
        XCTAssertEqual(ledger.lastConfirmedManagedFocus?.token, token)
    }

    func testRequiredRaiseCanBeQueuedAfterFocusConfirms() throws {
        let ledger = IntentLedger()
        let token = WindowToken(pid: 831_009, windowId: 831_109)
        let request = ledger.beginManagedRequest(token: token, workspaceId: .init())
        ledger.enableDeferredRetryRaise(for: request, required: true)

        XCTAssertNotNil(ledger.confirmManagedRequest(token: token, source: .focusedWindowChanged))

        let job = try XCTUnwrap(ledger.beginDeferredRetryRaise(for: request))
        XCTAssertFalse(job.isCancelled)
        XCTAssertNil(ledger.completeDeferredRetryRaise(job: job))
        XCTAssertFalse(ledger.defersRetryRaise(for: request))
        XCTAssertNil(ledger.activeManagedRequest)
    }

    func testRequiredRaiseCancelsWhenConfirmedNativeFocusMovesAway() throws {
        let otherFocus: [WindowToken?] = [WindowToken(pid: 831_015, windowId: 831_115), nil]
        for nativeToken in otherFocus {
            let ledger = IntentLedger()
            let token = WindowToken(pid: 831_014, windowId: 831_114)
            let request = ledger.beginManagedRequest(token: token, workspaceId: .init())
            ledger.enableDeferredRetryRaise(for: request, required: true)
            let job = try XCTUnwrap(ledger.beginDeferredRetryRaise(for: request))

            ledger.cancelConfirmedWorkerRaise(unlessFocused: nativeToken)

            XCTAssertFalse(job.isCancelled)
            XCTAssertTrue(ledger.defersRetryRaise(for: request))
            XCTAssertNotNil(ledger.confirmManagedRequest(token: token, source: .focusedWindowChanged))

            ledger.cancelConfirmedWorkerRaise(unlessFocused: token)

            XCTAssertFalse(job.isCancelled)
            XCTAssertTrue(ledger.defersRetryRaise(for: request))

            ledger.cancelConfirmedWorkerRaise(unlessFocused: nativeToken)

            XCTAssertTrue(job.isCancelled)
            XCTAssertFalse(ledger.defersRetryRaise(for: request))
            XCTAssertNil(ledger.completeDeferredRetryRaise(job: job))
        }
    }

    func testRequiredRaiseCompletionBeforeConfirmationPreservesPendingFocus() throws {
        let ledger = IntentLedger()
        let token = WindowToken(pid: 831_010, windowId: 831_110)
        let request = ledger.beginManagedRequest(token: token, workspaceId: .init())
        ledger.enableDeferredRetryRaise(for: request, required: true)
        let job = try XCTUnwrap(ledger.beginDeferredRetryRaise(for: request))

        XCTAssertEqual(ledger.completeDeferredRetryRaise(job: job), request)
        XCTAssertNil(ledger.completeDeferredRetryRaise(job: job))
        XCTAssertEqual(ledger.activeManagedRequest, request)

        XCTAssertNotNil(ledger.confirmManagedRequest(token: token, source: .focusedWindowChanged))

        XCTAssertNil(ledger.activeManagedRequest)
        XCTAssertFalse(ledger.defersRetryRaise(for: request))
        XCTAssertNil(ledger.beginDeferredRetryRaise(for: request))
    }

    func testRequiredRaiseCancelsOnNewFocusAndLifecycleChangesBeforeOrAfterConfirmation() throws {
        for confirmsFirst in [false, true] {
            for transition in 0 ..< 5 {
                let ledger = IntentLedger()
                let token = WindowToken(pid: 831_011, windowId: 831_111)
                let request = ledger.beginManagedRequest(token: token, workspaceId: .init())
                ledger.enableDeferredRetryRaise(for: request, required: true)
                let job = try XCTUnwrap(ledger.beginDeferredRetryRaise(for: request))
                if confirmsFirst {
                    XCTAssertNotNil(ledger.confirmManagedRequest(token: token, source: .focusedWindowChanged))
                }
                switch transition {
                case 0:
                    _ = ledger.beginManagedRequest(
                        token: WindowToken(pid: token.pid + 1, windowId: token.windowId + 1),
                        workspaceId: request.workspaceId
                    )
                case 1:
                    _ = ledger.beginManagedRequest(token: token, workspaceId: request.workspaceId)
                case 2:
                    ledger.discardPendingFocus(token)
                case 3:
                    ledger.rekey(from: token, to: WindowToken(pid: token.pid, windowId: token.windowId + 1))
                default:
                    ledger.reset()
                }
                XCTAssertTrue(job.isCancelled, "confirmed=\(confirmsFirst) transition=\(transition)")
                XCTAssertFalse(ledger.defersRetryRaise(for: request))
                XCTAssertNil(ledger.completeDeferredRetryRaise(job: job))
            }
        }
    }

    func testSupersededRequiredRaiseCompletionDoesNotClearReplacementRaise() throws {
        let ledger = IntentLedger()
        let first = ledger.beginManagedRequest(
            token: WindowToken(pid: 831_012, windowId: 831_112), workspaceId: .init()
        )
        ledger.enableDeferredRetryRaise(for: first, required: true)
        let firstJob = try XCTUnwrap(ledger.beginDeferredRetryRaise(for: first))
        XCTAssertNotNil(ledger.confirmManagedRequest(token: first.token, source: .focusedWindowChanged))
        let replacement = ledger.beginManagedRequest(
            token: WindowToken(pid: 831_013, windowId: 831_113), workspaceId: first.workspaceId
        )
        ledger.enableDeferredRetryRaise(for: replacement, required: true)
        let replacementJob = try XCTUnwrap(ledger.beginDeferredRetryRaise(for: replacement))

        XCTAssertTrue(firstJob.isCancelled)
        XCTAssertNil(ledger.completeDeferredRetryRaise(job: firstJob))
        XCTAssertFalse(replacementJob.isCancelled)
        XCTAssertTrue(ledger.defersRetryRaise(for: replacement))
        XCTAssertNil(ledger.beginDeferredRetryRaise(for: replacement))
        XCTAssertEqual(ledger.completeDeferredRetryRaise(job: replacementJob), replacement)
    }

    func testSurvivingRequestGetsFreshDeadlineWhenQueuedRetryIsInvalidated() throws {
        for transition in 0 ..< 3 {
            let ledger = IntentLedger()
            let wheel = DeadlineWheel()
            ledger.deadlineWheel = wheel
            defer { wheel.stop() }
            let token = WindowToken(pid: 831_002, windowId: 831_102)
            let request = ledger.beginManagedRequest(token: token, workspaceId: .init())
            let consumed = wheel.schedule(intentId: request.requestId, after: .seconds(10))
            XCTAssertTrue(wheel.consumeExpiration(intentId: request.requestId, generation: consumed))
            ledger.enableDeferredRetryRaise(for: request)
            let job = try XCTUnwrap(ledger.beginDeferredRetryRaise(for: request))
            switch transition {
            case 0:
                _ = ledger.beginManagedRequest(token: token, workspaceId: request.workspaceId)
            case 1:
                _ = ledger.retargetManagedRequest(requestId: request.requestId, token: token, to: .init())
            default:
                ledger.rekey(from: token, to: WindowToken(pid: token.pid, windowId: token.windowId + 1))
            }
            XCTAssertTrue(job.isCancelled)
            XCTAssertNil(ledger.completeDeferredRetryRaise(job: job))
            XCTAssertNotNil(ledger.activeManagedRequest(requestId: request.requestId))
            XCTAssertTrue(wheel.consumeExpiration(intentId: request.requestId, generation: consumed + 1))
        }
    }

    func testContextCancellationCompletesLiveRequestOnlyOnce() throws {
        let ledger = IntentLedger()
        let request = ledger.beginManagedRequest(
            token: WindowToken(pid: 831_003, windowId: 831_103), workspaceId: .init()
        )
        ledger.enableDeferredRetryRaise(for: request)
        let job = try XCTUnwrap(ledger.beginDeferredRetryRaise(for: request))
        XCTAssertNil(ledger.beginDeferredRetryRaise(for: request))
        job.cancel()
        XCTAssertEqual(ledger.completeDeferredRetryRaise(job: job), request)
        XCTAssertNil(ledger.completeDeferredRetryRaise(job: job))
        XCTAssertNotNil(ledger.beginDeferredRetryRaise(for: request))
    }

    func testWorkerRejectsCancelledSuppressedMissingAndReplacedWindows() {
        let window = AXWindowRef(element: AXUIElementCreateApplication(831_004), windowId: 831_104)
        $appThreadToken.withValue(AppThreadToken(pid: 831_004)) {
            for allowsLayoutHiddenWindow in [false, true] {
                for scenario in WorkerScenario.allCases {
                    let windows = ThreadGuardedValue([window.windowId: window.element])
                    defer { windows.destroy() }
                    let suppression = LockedWindowIdSet()
                    let job = RunLoopJob()
                    switch scenario {
                    case .cancelled: job.cancel()
                    case .frameSuppressed: suppression.insert(window.windowId)
                    case .appSuppressed: suppression.setHardSuppressed(true)
                    case .missing: windows[window.windowId] = nil
                    case .replaced: windows[window.windowId] = AXUIElementCreateApplication(831_005)
                    case .accepted: break
                    }
                    var didRaise = false
                    let result = AppAXContext.performRetryRaise(
                        window, windows: windows, suppression: suppression, job: job,
                        awaitingSubmittedFocus: {}, allowsLayoutHiddenWindow: allowsLayoutHiddenWindow,
                        raiseWindow: { _ in didRaise = true
                            return true
                        }
                    )
                    let expected = scenario == .accepted || (scenario == .frameSuppressed && allowsLayoutHiddenWindow)
                    XCTAssertEqual(result, expected)
                    XCTAssertEqual(didRaise, expected)
                }
            }
        }
    }

    func testWorkerWaitsForSubmittedFocusBeforeRaisingAndSkipsRaiseCancelledDuringWait() {
        let window = AXWindowRef(element: AXUIElementCreateApplication(831_007), windowId: 831_107)
        $appThreadToken.withValue(AppThreadToken(pid: 831_007)) {
            for cancelledDuringWait in [false, true] {
                let windows = ThreadGuardedValue([window.windowId: window.element])
                defer { windows.destroy() }
                let job = RunLoopJob()
                var steps: [String] = []
                let raised = AppAXContext.performRetryRaise(
                    window, windows: windows, suppression: LockedWindowIdSet(), job: job,
                    awaitingSubmittedFocus: {
                        steps.append("wait")
                        if cancelledDuringWait { job.cancel() }
                    },
                    raiseWindow: { _ in
                        steps.append("raise")
                        return true
                    }
                )
                XCTAssertEqual(raised, !cancelledDuringWait)
                XCTAssertEqual(steps, cancelledDuringWait ? ["wait"] : ["wait", "raise"])
            }
        }
    }

    func testCancellingAnExecutingWorkerRaiseDoesNotWaitForTheRaise() {
        let job = RunLoopJob()
        let window = AXWindowRef(element: AXUIElementCreateApplication(831_006), windowId: 831_106)
        $appThreadToken.withValue(AppThreadToken(pid: 831_006)) {
            let windows = ThreadGuardedValue([window.windowId: window.element])
            defer { windows.destroy() }
            var steps: [String] = []
            let raised = AppAXContext.performRetryRaise(
                window, windows: windows, suppression: LockedWindowIdSet(), job: job,
                awaitingSubmittedFocus: {},
                raiseWindow: { _ in
                    steps.append("entered")
                    job.cancel()
                    steps.append("cancelled")
                    return true
                }
            )
            XCTAssertTrue(raised)
            XCTAssertTrue(job.isCancelled)
            XCTAssertEqual(steps, ["entered", "cancelled"])
        }
    }

    func testLayoutHiddenWorkerRaiseBypassesOnlySoftSuppression() {
        let window = AXWindowRef(element: AXUIElementCreateApplication(831_008), windowId: 831_108)
        $appThreadToken.withValue(AppThreadToken(pid: 831_008)) {
            let windows = ThreadGuardedValue([window.windowId: window.element])
            defer { windows.destroy() }
            for allowsLayoutHiddenWindow in [false, true] {
                for hardSuppressed in [false, true] {
                    for windowHardSuppressed in [false, true] {
                        let suppression = LockedWindowIdSet()
                        suppression.insert(window.windowId)
                        suppression.setHardSuppressed(hardSuppressed)
                        suppression.setHardSuppressed(windowHardSuppressed, for: window.windowId)
                        var didRaise = false
                        let raised = AppAXContext.performRetryRaise(
                            window, windows: windows, suppression: suppression, job: RunLoopJob(),
                            awaitingSubmittedFocus: {}, allowsLayoutHiddenWindow: allowsLayoutHiddenWindow,
                            raiseWindow: { _ in didRaise = true
                                return true
                            }
                        )
                        let expected = allowsLayoutHiddenWindow && !hardSuppressed && !windowHardSuppressed
                        XCTAssertEqual(raised, expected)
                        XCTAssertEqual(didRaise, expected)
                    }
                }
            }
        }
    }
}
