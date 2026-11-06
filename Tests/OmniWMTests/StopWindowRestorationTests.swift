// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

final class StopWindowRestorationTests: XCTestCase {
    private let usable = CGRect(x: 100, y: 40, width: 1000, height: 700)

    private func target(placement: StopWindowGeometry
        .Placement? = .topLeft(CGPoint(x: 400, y: 500))) -> StopWindowTarget
    {
        let token = WindowToken(pid: 696_001, windowId: 696_002)
        return StopWindowTarget(
            token: token,
            window: AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId),
            visibleFrame: usable, placement: placement
        )
    }

    func testRestoresPositionWithCurrentSizeAfterConfirmedUnminimize() {
        let fixture = Operations()
        fixture.minimized = true
        fixture.current = CGRect(x: 2000, y: -400, width: 370, height: 280)
        let result = restore(fixture)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.confirmedMinimized, false)
        XCTAssertEqual(result.frame, CGRect(x: 400, y: 220, width: 370, height: 280))
        XCTAssertEqual(fixture.events, ["read-minimized", "unminimize", "read-minimized", "read-frame", "position"])
        XCTAssertTrue(fixture.timeouts.dropLast().allSatisfy { $0 > 0 && $0 <= 0.5 })
        XCTAssertEqual(fixture.timeouts.last, 0)
    }

    func testFloatingOriginSurvivesLiveSizeChange() {
        let current = CGRect(x: 4000, y: -500, width: 350, height: 290)
        let destination = target(placement: .floatingOrigin(CGPoint(x: 220, y: 170))).destination(for: current)
        XCTAssertEqual(destination, CGRect(origin: CGPoint(x: 220, y: 170), size: current.size))
    }

    func testFloatingPlacementOnDifferentMonitorUsesCurrentSizeBeforeMapping() {
        let current = CGRect(x: 4000, y: -500, width: 300, height: 200)
        let destination = target(placement: .floatingNormalizedOrigin(CGPoint(x: 0.5, y: 0.5)))
            .destination(for: current)
        XCTAssertEqual(destination, CGRect(x: 450, y: 290, width: 300, height: 200))
    }

    func testClampsToUsableAreaAndAlignsOversizedTopLeftWithoutResizing() {
        let parked = CGRect(x: 2000, y: -500, width: 1300, height: 900)
        XCTAssertEqual(target().destination(for: parked), CGRect(x: 100, y: -160, width: 1300, height: 900))
        let normal = CGRect(x: 2000, y: -500, width: 300, height: 200)
        XCTAssertEqual(target(placement: nil).destination(for: normal), CGRect(x: 800, y: 40, width: 300, height: 200))
    }

    func testUnminimizedWindowDoesNotReceiveMinimizedWrite() {
        let fixture = Operations()
        XCTAssertNil(restore(fixture).failure)
        XCTAssertFalse(fixture.events.contains("unminimize"))
    }

    func testRefusedUnminimizeDoesNotMoveWindow() {
        let fixture = Operations()
        fixture.minimized = true
        fixture.acceptUnminimize = false
        XCTAssertEqual(restore(fixture).failure, StopRestorationError.unminimizeRefused.rawValue)
        XCTAssertEqual(fixture.events, ["read-minimized", "unminimize"])
    }

    func testUnminimizeRequiresNativeReadback() {
        let fixture = Operations()
        fixture.minimized = true
        fixture.applyUnminimize = false
        let result = restore(fixture)
        XCTAssertEqual(result.failure, StopRestorationError.unminimizeRefused.rawValue)
        XCTAssertEqual(result.confirmedMinimized, true)
        XCTAssertFalse(fixture.events.contains("position"))
    }

    func testUnavailableClosedWindowGeometryFailsWithoutPositionWrite() {
        let fixture = Operations()
        fixture.current = nil
        XCTAssertEqual(restore(fixture).failure, StopRestorationError.geometryUnavailable.rawValue)
        XCTAssertFalse(fixture.events.contains("position"))
    }

    func testUnverifiedPositionAndSizeChangesAreFailures() {
        let fixture = Operations()
        fixture.writeFailure = .verificationMismatch
        XCTAssertEqual(restore(fixture).failure, StopRestorationError.positionRefused.rawValue)
        fixture.writeFailure = nil
        fixture.resizeDuringWrite = true
        XCTAssertEqual(restore(fixture).failure, StopRestorationError.positionRefused.rawValue)
    }

    func testBudgetExhaustionPreventsNewWorkAndLimitsMessageTimeout() {
        let fixture = Operations()
        let result = AXStopWindowRestoration.perform(
            target(), deadline: 1, operations: fixture.operations, checkCancellation: {}, now: { 1 }
        )
        XCTAssertEqual(result.failure, StopRestorationError.deadlineExceeded.rawValue)
        XCTAssertTrue(fixture.events.isEmpty)
        fixture.timeouts = []
        _ = AXStopWindowRestoration.perform(
            target(), deadline: 1, operations: fixture.operations, checkCancellation: {}, now: { 0.8 }
        )
        XCTAssertTrue(fixture.timeouts.allSatisfy { $0 <= 0.2 })
        XCTAssertEqual(fixture.timeouts.dropLast().last!, 0.1)
    }

    func testDeadlineAfterNativeWriteDoesNotCountAsSuccess() {
        let fixture = Operations()
        var now: TimeInterval = 0
        fixture.afterWrite = { now = 2 }
        let result = AXStopWindowRestoration.perform(
            target(), deadline: 1, operations: fixture.operations, checkCancellation: {}, now: { now }
        )
        XCTAssertEqual(result.failure, StopRestorationError.deadlineExceeded.rawValue)
        XCTAssertNil(result.frame)
    }

    func testCancellationBetweenNativeOperationsPreventsFurtherWrites() {
        let fixture = Operations()
        let result = AXStopWindowRestoration.perform(
            target(), deadline: 1, operations: fixture.operations,
            checkCancellation: { if !fixture.events.isEmpty { throw CancellationError() } }, now: { 0 }
        )
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(fixture.events, ["read-minimized"])
    }

    private func restore(_ fixture: Operations) -> StopWindowOutcome {
        AXStopWindowRestoration.perform(
            target(),
            deadline: 1,
            operations: fixture.operations,
            checkCancellation: {},
            now: { 0 }
        )
    }

    private final class Operations {
        var minimized: Bool? = false
        var acceptUnminimize = true
        var applyUnminimize = true
        var current: CGRect? = CGRect(x: 2000, y: -400, width: 300, height: 200)
        var writeFailure: AXFrameWriteFailureReason?
        var resizeDuringWrite = false
        var afterWrite: () -> Void = {}
        var events: [String] = []
        var timeouts: [Float] = []

        var operations: StopWindowOperations {
            StopWindowOperations(
                setTimeout: { self.timeouts.append($0)
                    return true
                },
                readMinimized: { self.events.append("read-minimized")
                    return self.minimized
                },
                unminimize: {
                    self.events.append("unminimize")
                    if self.acceptUnminimize, self.applyUnminimize { self.minimized = false }
                    return self.acceptUnminimize
                },
                readFrame: { self.events.append("read-frame")
                    return self.current
                },
                writePosition: { destination, _ in
                    self.events.append("position")
                    var observed = destination
                    if self.resizeDuringWrite { observed.size.width += 20 }
                    self.afterWrite()
                    return AXFrameWriteResult(
                        observedFrame: observed, writeOrder: .sizeThenPosition, sizeError: .success,
                        positionError: .success, failureReason: self.writeFailure, components: .position
                    )
                }
            )
        }
    }
}
