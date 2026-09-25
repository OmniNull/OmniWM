// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class StaleFrameWriteParkingTests: XCTestCase {
    private let pid: pid_t = 975_001
    private let windowId = 975_101
    private let visibleFrame = CGRect(x: 96, y: 15, width: 1259, height: 1380)
    private let parkFrame = CGRect(x: -1258, y: 15, width: 1259, height: 1380)

    func testWriteFinishingAfterParkingReassertsLatestTargetWithoutAcceptingStaleLayout() throws {
        let manager = AXManager()
        let generations = LockedWindowGenerationMap()
        let request = try makeRequest(manager: manager, generations: generations)
        var parked = false
        var physicalFrame = visibleFrame
        var accepted = false
        manager.isWindowParked = { _ in parked }
        manager.onFrameApplySucceeded = { _ in accepted = true }
        let latestParkFrame = CGRect(x: 3023, y: 15, width: 1259, height: 1380)

        let result = applyFrameWriteRequest(
            request, pid: pid, generations: generations,
            writeFrame: { _, frame, _, components, _ in
                parked = true
                manager.suppressFrameWrites([(self.pid, self.windowId)])
                _ = generations.nextGeneration(for: self.windowId)
                manager.markParkPending(.init(pid: self.pid, window: request.expectedWindow, frame: self.parkFrame))
                manager.markParkPending(.init(pid: self.pid, window: request.expectedWindow, frame: latestParkFrame))
                manager.recordSkyLightMove(windowId: self.windowId, origin: latestParkFrame.origin)
                physicalFrame = frame
                return self.success(frame, components: components)
            }
        )

        XCTAssertEqual(physicalFrame, visibleFrame)
        XCTAssertEqual(result.writeResult.failureReason, .cancelled)
        XCTAssertTrue(result.didAttemptWrite)
        XCTAssertNil(result.confirmedFrame)
        var correctedFrames: [CGRect] = []
        manager.handleFrameApplyResults([result], applyParkPosition: { target in
            correctedFrames.append(target.frame)
            physicalFrame = target.frame
            return .submitted
        })

        XCTAssertEqual(correctedFrames, [latestParkFrame])
        XCTAssertEqual(physicalFrame, latestParkFrame)
        XCTAssertEqual(manager.skyLightLivePosition(for: windowId), latestParkFrame.origin)
        XCTAssertTrue(manager.pendingParkWindowIds.contains(windowId))
        XCTAssertNil(manager.frameLedger.lastAppliedFrame(for: windowId))
        XCTAssertFalse(accepted)
    }

    func testWriteSupersededAfterWorkerReturnsStillReassertsPark() throws {
        let manager = AXManager()
        let generations = LockedWindowGenerationMap()
        let request = try makeRequest(manager: manager, generations: generations)
        let result = successfulWrite(request, generations: generations)
        XCTAssertNil(result.writeResult.failureReason)
        XCTAssertTrue(result.didAttemptWrite)
        park(manager, window: request.expectedWindow)
        var correctedFrames: [CGRect] = []

        manager.handleFrameApplyResults([result], applyParkPosition: {
            correctedFrames.append($0.frame)
            return .submitted
        })

        XCTAssertEqual(correctedFrames, [parkFrame])
        XCTAssertNil(manager.frameLedger.lastAppliedFrame(for: windowId))
    }

    func testCancellationBeforeWriteDoesNotReassertPark() throws {
        let manager = AXManager()
        let generations = LockedWindowGenerationMap()
        let request = try makeRequest(manager: manager, generations: generations)
        _ = generations.nextGeneration(for: windowId)
        park(manager, window: request.expectedWindow)
        let result = applyFrameWriteRequest(
            request, pid: pid, generations: generations,
            writeFrame: { _, frame, _, components, _ in
                XCTFail("Cancelled request must not call AX")
                return self.success(frame, components: components)
            }
        )

        XCTAssertFalse(result.didAttemptWrite)
        manager.handleFrameApplyResults([result], applyParkPosition: { _ in
            XCTFail("A request cancelled before writing cannot disturb parking")
            return .submitted
        })
    }

    func testRevealedWindowIsNotReparkedByDiscardedCompletion() throws {
        let manager = AXManager()
        let generations = LockedWindowGenerationMap()
        let request = try makeRequest(manager: manager, generations: generations)
        let result = successfulWrite(request, generations: generations)
        park(manager, window: request.expectedWindow)
        manager.unsuppressFrameWrites([(pid, windowId)])
        manager.isWindowParked = { _ in false }

        manager.handleFrameApplyResults([result], applyParkPosition: { _ in
            XCTFail("A revealed window must stay visible")
            return .submitted
        })
        XCTAssertNil(manager.parkTargetFrame(for: windowId))
        XCTAssertFalse(manager.pendingParkWindowIds.contains(windowId))
    }

    func testRemovedOrReplacedWindowIsNotMovedByDiscardedCompletion() throws {
        for replacement in 0 ... 2 {
            let manager = AXManager()
            let generations = LockedWindowGenerationMap()
            let request = try makeRequest(manager: manager, generations: generations)
            let result = successfulWrite(request, generations: generations)
            park(manager, window: request.expectedWindow)
            manager.clearParkPending(for: windowId, pid: pid, reason: "removed")
            if replacement > 0 {
                let replacementWindow = AXWindowRef(
                    element: AXUIElementCreateApplication(pid + 1), windowId: windowId
                )
                manager.markParkPending(.init(
                    pid: replacement == 1 ? pid : pid + 1, window: replacementWindow, frame: parkFrame
                ))
            }

            manager.handleFrameApplyResults([result], applyParkPosition: { _ in
                XCTFail("Removed or replacement window must not inherit old writes")
                return .submitted
            })
        }
    }

    func testUnavailableCorrectionKeepsParkPendingAndInvalidatesCachedPosition() throws {
        let manager = AXManager()
        let generations = LockedWindowGenerationMap()
        let request = try makeRequest(manager: manager, generations: generations)
        let result = successfulWrite(request, generations: generations)
        park(manager, window: request.expectedWindow)
        manager.recordSkyLightMove(windowId: windowId, origin: parkFrame.origin)
        var submissions = 0

        manager.handleFrameApplyResults([result], applyParkPosition: { _ in
            submissions += 1
            return .unavailable
        })

        XCTAssertEqual(submissions, 1)
        XCTAssertNil(manager.skyLightLivePosition(for: windowId))
        XCTAssertTrue(manager.pendingParkWindowIdsAwaitingSkyLightMove.contains(windowId))
    }

    func testAcceptedRevealWriteIsNotInterceptedWhileHiddenStateAwaitsCompletion() throws {
        let manager = AXManager()
        let generations = LockedWindowGenerationMap()
        let request = try makeRequest(manager: manager, generations: generations)
        manager.isWindowParked = { _ in true }
        manager.markParkPending(.init(pid: pid, window: request.expectedWindow, frame: parkFrame))
        var accepted = false
        manager.onFrameApplySucceeded = { _ in accepted = true }
        let result = successfulWrite(request, generations: generations)

        manager.handleFrameApplyResults([result], applyParkPosition: { _ in
            XCTFail("An accepted reveal must complete its existing success path")
            return .submitted
        })

        XCTAssertTrue(accepted)
        XCTAssertEqual(manager.frameLedger.lastAppliedFrame(for: windowId), visibleFrame)
    }

    private func makeRequest(
        manager: AXManager, generations: LockedWindowGenerationMap
    ) throws -> AppAXFrameWriteRequest {
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let request = try XCTUnwrap(manager.frameLedger.prepareFrameApplication(
            .init(pid: pid, window: window, frame: visibleFrame, components: .position),
            isRetry: false, terminalObserver: nil
        ).request)
        return AppAXFrameWriteRequest(
            requestId: request.requestId, pid: pid, windowId: windowId, expectedWindow: window,
            frame: visibleFrame, currentFrameHint: nil, components: .position,
            generation: generations.nextGeneration(for: windowId), verify: false
        )
    }

    private func park(_ manager: AXManager, window: AXWindowRef) {
        manager.isWindowParked = { _ in true }
        manager.suppressFrameWrites([(pid, windowId)])
        manager.markParkPending(.init(pid: pid, window: window, frame: parkFrame))
    }

    private func successfulWrite(
        _ request: AppAXFrameWriteRequest, generations: LockedWindowGenerationMap
    ) -> AXFrameApplyResult {
        applyFrameWriteRequest(
            request, pid: pid, generations: generations,
            writeFrame: { _, frame, _, components, _ in self.success(frame, components: components) }
        )
    }

    private func success(_ frame: CGRect, components: AXFrameComponents) -> AXFrameWriteResult {
        AXFrameWriteResult(
            observedFrame: frame, writeOrder: .sizeThenPosition, sizeError: .success,
            positionError: .success, failureReason: nil, components: components
        )
    }
}
