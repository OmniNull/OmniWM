// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NativeWindowFrameSuppressionTests: XCTestCase {
    func testNativeWindowFenceSurvivesSoftUnsuppressionAndAppUnhide() {
        let delivery = AppAXFrameDelivery()
        let suppressedId = 688_101
        let visibleId = 688_102
        delivery.suppressFrameWrite(for: suppressedId)
        delivery.setWindowNativeSuppressed(true, for: suppressedId)
        delivery.setHardSuppressed(true)
        delivery.unsuppressFrameWrite(for: suppressedId)
        delivery.setHardSuppressed(false)

        XCTAssertTrue(delivery.retryRaiseSuppression.contains(suppressedId))
        XCTAssertTrue(delivery.retryRaiseSuppression.isHardSuppressed(for: suppressedId))
        XCTAssertFalse(delivery.retryRaiseSuppression.contains(visibleId))

        delivery.suppressFrameWrite(for: suppressedId)
        delivery.setWindowNativeSuppressed(false, for: suppressedId)
        XCTAssertTrue(delivery.retryRaiseSuppression.contains(suppressedId))
        XCTAssertFalse(delivery.retryRaiseSuppression.isHardSuppressed(for: suppressedId))
        delivery.unsuppressFrameWrite(for: suppressedId)
        XCTAssertFalse(delivery.retryRaiseSuppression.contains(suppressedId))

        delivery.setHardSuppressed(true)
        delivery.setWindowNativeSuppressed(false, for: suppressedId)
        XCTAssertTrue(delivery.retryRaiseSuppression.isHardSuppressed(for: suppressedId))
    }

    func testWorkerRejectsNativeSuppressedOrdinaryAndParkWritesAfterSoftUnsuppression() throws {
        for lane: AppAXFrameLane in [.ordinary, .park] {
            let delivery = AppAXFrameDelivery()
            defer { delivery.shutdown() }
            let request = frameRequest()
            delivery.setWindowNativeSuppressed(true, for: request.windowId)
            delivery.unsuppressFrameWrite(for: request.windowId)
            let drain = try enqueue(request, lane: lane, delivery: delivery)
            let results = execute(drain, lane: lane, delivery: delivery)

            XCTAssertEqual(results.map(\.writeResult.failureReason), [.suppressed])
        }
    }

    func testSuppressAndRestoreInvalidatePreviouslyQueuedOrdinaryAndParkWrites() throws {
        for lane: AppAXFrameLane in [.ordinary, .park] {
            let delivery = AppAXFrameDelivery()
            defer { delivery.shutdown() }
            let request = frameRequest()
            let drain = try enqueue(request, lane: lane, delivery: delivery)
            delivery.setWindowNativeSuppressed(true, for: request.windowId)
            delivery.setWindowNativeSuppressed(false, for: request.windowId)
            let results = execute(drain, lane: lane, delivery: delivery)

            XCTAssertEqual(results.map(\.writeResult.failureReason), [.cancelled])
        }
    }

    func testWorkerRejectsClosingWriteForNativeSuppressedWindow() throws {
        let delivery = AppAXFrameDelivery()
        defer { delivery.shutdown() }
        let request = frameRequest()
        let drain = try XCTUnwrap(delivery.enqueueClosingFrames([
            .init(
                animationId: UUID(), pid: request.pid, expectedWindow: request.expectedWindow,
                frame: request.frame, currentFrameHint: nil
            )
        ]))
        delivery.setWindowNativeSuppressed(true, for: request.windowId)
        delivery.unsuppressFrameWrite(for: request.windowId)

        let cancelled = delivery.closingExecution(
            metricsToken: .init(pid: request.pid, callbackGeneration: 0)
        ).execute(drain, job: RunLoopJob())

        XCTAssertEqual(cancelled, 1)
    }

    func testWorkerRejectsRetryRaiseForNativeSuppressedWindow() {
        let request = frameRequest()
        let delivery = AppAXFrameDelivery()
        delivery.setWindowNativeSuppressed(true, for: request.windowId)
        $appThreadToken.withValue(AppThreadToken(pid: request.pid)) {
            let windows = ThreadGuardedValue([request.windowId: request.expectedWindow.element])
            defer { windows.destroy() }
            var raises = 0
            let raised = AppAXContext.performRetryRaise(
                request.expectedWindow,
                windows: windows,
                suppression: delivery.retryRaiseSuppression,
                job: RunLoopJob(),
                awaitingSubmittedFocus: {},
                raiseWindow: { _ in
                    raises += 1
                    return true
                }
            )

            XCTAssertFalse(raised)
            XCTAssertEqual(raises, 0)
        }
    }

    func testSuppressAndRestoreCancelOnlyMatchingQueuedClosingWrite() throws {
        let delivery = AppAXFrameDelivery()
        defer { delivery.shutdown() }
        let request = frameRequest()
        let visibleWindowId = request.windowId + 1
        let targets = [request.windowId, visibleWindowId].map { windowId in
            AXClosingFrameTarget(
                animationId: UUID(),
                pid: request.pid,
                expectedWindow: .init(element: request.expectedWindow.element, windowId: windowId),
                frame: request.frame,
                currentFrameHint: nil
            )
        }
        let drain = try XCTUnwrap(delivery.enqueueClosingFrames(targets))
        let execution = delivery.closingExecution(metricsToken: .init(pid: request.pid, callbackGeneration: 0))
        delivery.setWindowNativeSuppressed(true, for: request.windowId)
        delivery.setWindowNativeSuppressed(false, for: request.windowId)
        var writtenWindowIds: [Int] = []
        var outcomes: [Int: AXClosingFrameWriteOutcome] = [:]

        for queued in drain.requests {
            outcomes[queued.target.windowId] = applyClosingFrameWriteRequest(
                queued,
                generations: execution.generations,
                isCancelled: { execution.suppression.isHardSuppressed(for: queued.target.windowId) },
                writeFrame: { window, _, _, _ in
                    writtenWindowIds.append(window.windowId)
                    return .init(
                        observedFrame: nil, writeOrder: .sizeThenPosition,
                        sizeError: .success, positionError: .success, failureReason: nil
                    )
                }
            )
        }

        XCTAssertEqual(outcomes[request.windowId], .ineligible)
        XCTAssertEqual(writtenWindowIds, [visibleWindowId])
    }

    func testSkyLightFilteringExcludesOnlyNativeSuppressedWindowEvenWhenAllowingInactiveWindows() {
        let manager = AXManager()
        defer { manager.cleanup() }
        let suppressedToken = WindowToken(pid: 688_201, windowId: 688_101)
        let visibleToken = WindowToken(pid: suppressedToken.pid, windowId: suppressedToken.windowId + 1)
        let positions = [suppressedToken, visibleToken].map {
            SkyLightPositionTarget(token: $0, frame: CGRect(x: 10, y: 20, width: 300, height: 200))
        }
        manager.setWindowNativeSuppressed(true, token: suppressedToken)
        manager.markWindowInactive(suppressedToken.windowId)

        XCTAssertEqual(manager.positionsAllowedToWrite(positions, allowInactive: false).map(\.token), [visibleToken])
        XCTAssertEqual(manager.positionsAllowedToWrite(positions, allowInactive: true).map(\.token), [visibleToken])

        manager.setWindowNativeSuppressed(false, token: suppressedToken)
        XCTAssertEqual(
            manager.positionsAllowedToWrite(positions, allowInactive: true).map(\.token),
            [suppressedToken, visibleToken]
        )
    }

    func testWorkerFenceMovesWithWindowAndClearsOnRetirement() {
        let delivery = AppAXFrameDelivery()
        delivery.setWindowNativeSuppressed(true, for: 688_101)
        delivery.prepareWindowRebind(from: 688_101, to: 688_102)

        XCTAssertFalse(delivery.retryRaiseSuppression.contains(688_101))
        XCTAssertTrue(delivery.retryRaiseSuppression.contains(688_102))

        delivery.prepareWindowRemoval(for: 688_102)
        XCTAssertFalse(delivery.retryRaiseSuppression.contains(688_102))
    }

    func testManagerNativeSuppressionRejectsNewFramesAndPreservesUnrelatedAppVisibility() {
        let manager = AXManager()
        defer { manager.cleanup() }
        let request = frameRequest()
        let token = WindowToken(pid: request.pid, windowId: request.windowId)
        let entries = [(pid: token.pid, windowId: token.windowId)]
        manager.setWindowNativeSuppressed(true, token: token)
        manager.setMacOSAppHidden(true, pid: token.pid, entries: entries)
        manager.setMacOSAppHidden(false, pid: token.pid, entries: entries)
        manager.unsuppressFrameWrites(entries)
        var deliveredResults: [AXFrameApplyResult] = []
        manager.applyFramesParallel([
            .init(pid: token.pid, window: request.expectedWindow, frame: request.frame)
        ], terminalObserver: { deliveredResults.append($0) })
        manager.applyParkFramesParallel([
            .init(pid: token.pid, window: request.expectedWindow, frame: request.frame)
        ])

        XCTAssertTrue(manager.isWindowNativeSuppressed(token))
        XCTAssertFalse(manager.isWindowNativeSuppressed(.init(pid: token.pid, windowId: token.windowId + 1)))
        XCTAssertNil(manager.frameLedger.pendingFrameWrite(for: token.windowId))
        XCTAssertNil(manager.pendingParkFrameRequest(for: token.windowId))
        XCTAssertTrue(deliveredResults.isEmpty)

        manager.removeWindowLedgerState(pid: token.pid, windowId: token.windowId)
        XCTAssertFalse(manager.isWindowNativeSuppressed(token))
    }

    func testRegistryFenceFollowsRekeyAndSurvivesMissingContext() {
        let oldToken = WindowToken(pid: 688_201, windowId: 688_101)
        let newToken = WindowToken(pid: 688_202, windowId: 688_102)
        defer { AppAXContextRegistry.setWindowNativeSuppressed(false, token: newToken) }
        AppAXContextRegistry.setWindowNativeSuppressed(true, token: oldToken)
        AppAXContextRegistry.rekeyNativeSuppressedWindow(from: oldToken, to: newToken)

        XCTAssertFalse(AppAXContextRegistry.nativeSuppressedWindowTokens.contains(oldToken))
        XCTAssertTrue(AppAXContextRegistry.nativeSuppressedWindowTokens.contains(newToken))
    }

    private func frameRequest() -> AXFrameApplicationRequest {
        .init(
            requestId: 1,
            pid: 688_201,
            windowId: 688_101,
            expectedWindow: .init(element: AXUIElementCreateApplication(688_201), windowId: 688_101),
            frame: CGRect(x: 10, y: 20, width: 300, height: 200),
            currentFrameHint: nil
        )
    }

    private func enqueue(
        _ request: AXFrameApplicationRequest,
        lane: AppAXFrameLane,
        delivery: AppAXFrameDelivery
    ) throws -> AppAXFrameMailbox.Drain {
        let outcome = lane == .ordinary
            ? delivery.enqueueFrames([request], callbackGeneration: 0) { _ in }
            : delivery.enqueueParkFrames([request], callbackGeneration: 0) { _ in }
        return try XCTUnwrap(outcome.drain)
    }

    private func execute(
        _ drain: AppAXFrameMailbox.Drain,
        lane: AppAXFrameLane,
        delivery: AppAXFrameDelivery
    ) -> [AXFrameApplyResult] {
        delivery.writer(trace: .init(
            context: .init(pid: 688_201, callbackGeneration: 0),
            bundleId: nil,
            lane: lane,
            drainId: drain.id
        )).execute(
            drain.items.span,
            axApp: AXUIElementCreateApplication(688_201),
            isCancelled: { false }
        )
    }
}
