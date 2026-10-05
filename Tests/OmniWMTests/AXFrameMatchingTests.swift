// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class AXFrameMatchingTests: XCTestCase {
    func testFractionalResizeMatchesAXTopLeftWithinExistingTolerance() {
        let target = CGRect(x: 10, y: 10, width: 1_265, height: 692.5)
        let observed = CGRect(x: 10, y: 9, width: 1_265, height: 693)

        XCTAssertTrue(axFrameMatches(observed, target: target, components: .all))
    }

    func testPositionToleranceStillExcludesAnExactOnePointDifference() {
        let target = CGRect(x: 10, y: 10, width: 1_265, height: 692.5)
        let differentTop = CGRect(x: 10, y: 8.5, width: 1_265, height: 693)
        let differentLeft = CGRect(x: 11, y: 9, width: 1_265, height: 693)

        XCTAssertFalse(axFrameMatches(differentTop, target: target, components: .all))
        XCTAssertFalse(axFrameMatches(differentLeft, target: target, components: .all))
    }

    func testMatchingTopLeftDoesNotAcceptARefusedSize() {
        let target = CGRect(x: 10, y: 10, width: 1_265, height: 692.5)
        let observed = CGRect(x: 10, y: 9, width: 1_265, height: 693.5)

        XCTAssertTrue(axFrameMatches(observed, target: target, components: .position))
        XCTAssertFalse(axFrameMatches(observed, target: target, components: .size))
        XCTAssertFalse(axFrameMatches(observed, target: target, components: .all))
    }

    func testPositionOnlyMatchingUsesTheTopEdgeWhenHeightDiffers() {
        let target = CGRect(x: 40, y: 50, width: 500, height: 400)
        let sameTop = CGRect(x: 40, y: 210, width: 320, height: 240)
        let sameBottom = CGRect(x: 40, y: 50, width: 320, height: 240)

        XCTAssertTrue(axFrameMatches(sameTop, target: target, components: .position))
        XCTAssertFalse(axFrameMatches(sameBottom, target: target, components: .position))
        XCTAssertFalse(axFrameMatches(sameTop, target: target, components: .all))
    }

    func testSizeOnlyMatchingIgnoresBothPositionCoordinates() {
        let target = CGRect(x: 10, y: 20, width: 300, height: 200)
        let observed = CGRect(x: 100, y: 400, width: 300, height: 200)

        XCTAssertTrue(axFrameMatches(observed, target: target, components: .size))
        XCTAssertFalse(axFrameMatches(observed, target: target, components: .all))
    }

    func testFractionalResizeReplacesOldGeometryWithoutRetryAndDeduplicatesTarget() throws {
        let ledger = AXFrameApplicationLedger()
        let pid = getpid()
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 467_601)
        let target = CGRect(x: 10, y: 10, width: 1_265, height: 692.5)
        let observed = CGRect(x: 10, y: 9, width: 1_265, height: 693)
        ledger.confirmFrameWrite(
            for: window.windowId,
            frame: CGRect(x: 10, y: 10, width: 1_265, height: 1_395)
        )
        let request = try XCTUnwrap(WindowAdmissionTestSupport.frameRequest(
            ledger, pid: pid, window: window, frame: target
        ))
        var accepted: [AXFrameApplyResult] = []

        let outcome = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.verificationMismatchFrameResult(request: request, observed: observed)
        ]) { accepted.append($0) }

        XCTAssertEqual(accepted.map(\.confirmedFrame), [observed])
        XCTAssertEqual(ledger.lastAppliedFrame(for: window.windowId), observed)
        XCTAssertEqual(ledger.trustedVerifiedSize(for: window.windowId), observed.size)
        XCTAssertFalse(ledger.hasPendingFrameWrite(for: window.windowId))
        XCTAssertNil(ledger.recentFrameWriteFailure(for: window.windowId))
        XCTAssertTrue(outcome.retries.isEmpty)
        XCTAssertTrue(outcome.terminalRefusals.isEmpty)
        XCTAssertTrue(outcome.terminalFailures.isEmpty)
        XCTAssertNil(WindowAdmissionTestSupport.frameRequest(
            ledger, pid: pid, window: window, frame: target
        ))
    }

    func testVerifiedPositionCacheDeduplicatesOnlyTheSameTopLeft() {
        let ledger = AXFrameApplicationLedger()
        let pid = getpid()
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 467_602)
        let observed = CGRect(x: 40, y: 210, width: 320, height: 240)
        ledger.confirmFrameWrite(for: window.windowId, frame: observed)

        let sameTop = ledger.prepareFrameApplication(
            .init(
                pid: pid, window: window,
                frame: CGRect(x: 40, y: 50, width: 500, height: 400), components: .position
            ),
            isRetry: false,
            terminalObserver: nil
        )
        XCTAssertNil(sameTop.request)

        let sameBottom = ledger.prepareFrameApplication(
            .init(
                pid: pid, window: window,
                frame: CGRect(x: 40, y: 210, width: 500, height: 400), components: .position
            ),
            isRetry: false,
            terminalObserver: nil
        )
        XCTAssertNotNil(sameBottom.request)
    }
}
