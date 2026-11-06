// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Dispatch
import Foundation
@testable import OmniWM
import XCTest

final class AutomaticAXSnapshotTests: XCTestCase {
    private enum TimeoutProbeError: Error {
        case expected
    }

    func testExactWindowSelectionPrecedesFocusedFallback() {
        let focused = AXUIElementCreateApplication(91_010)
        let other = AXUIElementCreateApplication(91_011)
        let target = AXUIElementCreateApplication(91_012)

        let selected = AutomaticAXSnapshotCollector.selectWindowElement(
            windowId: 22,
            focusedWindow: focused,
            windows: [other, target]
        ) { element in
            CFEqual(element, target) ? 22 : 11
        }

        XCTAssertNotNil(selected)
        XCTAssertTrue(selected.map { CFEqual($0, target) } == true)
    }

    func testFocusedWindowIsUsedWithoutExactWindowIdentity() {
        let focused = AXUIElementCreateApplication(91_020)
        var resolvedWindowId = false

        let selected = AutomaticAXSnapshotCollector.selectWindowElement(
            windowId: nil,
            focusedWindow: focused,
            windows: [AXUIElementCreateApplication(91_021)]
        ) { _ in
            resolvedWindowId = true
            return nil
        }

        XCTAssertNotNil(selected)
        XCTAssertTrue(selected.map { CFEqual($0, focused) } == true)
        XCTAssertFalse(resolvedWindowId)
    }

    func testFocusedWindowIsUsedWhenItResolvesToRequestedIdentity() {
        let focused = AXUIElementCreateApplication(91_022)
        let other = AXUIElementCreateApplication(91_023)

        let selected = AutomaticAXSnapshotCollector.selectWindowElement(
            windowId: 22,
            focusedWindow: focused,
            windows: [other]
        ) { element in
            CFEqual(element, focused) ? 22 : 11
        }

        XCTAssertNotNil(selected)
        XCTAssertTrue(selected.map { CFEqual($0, focused) } == true)
    }

    func testFocusedWindowIsNotSubstitutedWhenIdentityDoesNotMatch() {
        let focused = AXUIElementCreateApplication(91_024)
        let other = AXUIElementCreateApplication(91_025)

        let selected = AutomaticAXSnapshotCollector.selectWindowElement(
            windowId: 22,
            focusedWindow: focused,
            windows: [other]
        ) { _ in 11 }

        XCTAssertNil(selected)
    }

    func testMessagingTimeoutIsRestoredWhenSnapshotReadThrows() {
        let element = AXUIElementCreateApplication(91_030)
        var timeouts: [Float] = []

        XCTAssertThrowsError(
            try AutomaticAXSnapshotCollector.withMessagingTimeout(
                element,
                setter: { _, timeout in timeouts.append(timeout) }
            ) {
                throw TimeoutProbeError.expected
            }
        )
        XCTAssertEqual(timeouts, [0.5, 0])
    }

    func testRequestReasonIsUTF8ByteBounded() {
        let request = AutomaticAXSnapshotRequest(
            reason: String(repeating: "🪟", count: 4_096),
            pid: 91_031,
            windowId: nil
        )

        XCTAssertLessThanOrEqual(request.reason.utf8.count, RuntimeTraceLimits.diagnosticStringBytes)
        XCTAssertNotNil(String(data: Data(request.reason.utf8), encoding: .utf8))
    }

    func testOverallTimeoutProducesEncodableSnapshot() async throws {
        let gate = AutomaticSnapshotCaptureGate()
        let watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return false
            }
            gate.release()
            return true
        }
        defer {
            watchdog.cancel()
            gate.release()
        }
        let started = expectation(description: "snapshot capture started")
        let collector = AutomaticAXSnapshotCollector(overallTimeoutSeconds: 0.01) { request in
            started.fulfill()
            gate.wait()
            return AutomaticAXSnapshot(
                generatedAt: Date().ISO8601Format(),
                reason: request.reason,
                pid: request.pid,
                windowId: request.windowId,
                status: "late",
                app: nil,
                window: nil
            )
        }
        let request = AutomaticAXSnapshotRequest(
            reason: "timeout_test",
            pid: 91_001,
            windowId: 91_002
        )

        let capture = Task { await collector.capture(request) }
        await fulfillment(of: [started], timeout: failureBound)
        let snapshot = await capture.value
        watchdog.cancel()
        let watchdogFired = await watchdog.value
        let encoded = collector.encoded(snapshot)
        let decoded = try JSONDecoder().decode(AutomaticAXSnapshot.self, from: Data(encoded.utf8))

        XCTAssertFalse(watchdogFired, "snapshot capture exceeded the watchdog deadline")
        XCTAssertEqual(decoded.status, "timed_out")
        XCTAssertEqual(decoded.reason, "timeout_test")
        XCTAssertEqual(decoded.windowId, 91_002)
    }

    func testUnavailableTargetStillProducesStructuredEvidence() async throws {
        let collector = AutomaticAXSnapshotCollector(overallTimeoutSeconds: 1)
        let request = AutomaticAXSnapshotRequest(
            reason: "missing_target",
            pid: Int32.max,
            windowId: Int.max
        )

        let snapshot = await collector.capture(request)
        let encoded = collector.encoded(snapshot)
        let decoded = try JSONDecoder().decode(AutomaticAXSnapshot.self, from: Data(encoded.utf8))

        XCTAssertNotEqual(decoded.status, "captured")
        XCTAssertEqual(decoded.pid, Int32.max)
        XCTAssertEqual(decoded.windowId, Int.max)
    }
}

private final class AutomaticSnapshotCaptureGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false

    func wait() {
        lock.lock()
        if released {
            lock.unlock()
            return
        }
        lock.unlock()
        semaphore.wait()
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        semaphore.signal()
    }
}
