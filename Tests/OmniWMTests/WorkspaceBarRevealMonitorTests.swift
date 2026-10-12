// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarRevealMonitorTests: XCTestCase {
    private let option = CGEventFlags.maskAlternate.rawValue

    func testZeroDelayPressAndRelease() {
        let monitor = WorkspaceBarRevealMonitor(modifier: .option, holdMilliseconds: 0)
        var callbacks: [Bool] = []
        monitor.onRevealChanged = { callbacks.append($0) }

        monitor.handleFlagsChanged(rawFlags: option)
        monitor.handleFlagsChanged(rawFlags: 0)

        XCTAssertEqual(callbacks, [true, false])
    }

    func testRepeatedHeldEventsEmitNothingExtra() {
        let monitor = WorkspaceBarRevealMonitor(modifier: .option, holdMilliseconds: 0)
        var callbacks: [Bool] = []
        monitor.onRevealChanged = { callbacks.append($0) }

        monitor.handleFlagsChanged(rawFlags: option)
        monitor.handleFlagsChanged(rawFlags: option)
        monitor.handleFlagsChanged(rawFlags: option)

        XCTAssertEqual(callbacks, [true])
    }

    func testDelayedPressQuickReleaseNeverReveals() async throws {
        let sleeper = ManualSleeper()
        let monitor = WorkspaceBarRevealMonitor(modifier: .option, holdMilliseconds: 50) {
            try await sleeper.sleep(for: $0)
        }
        var callbacks: [Bool] = []
        monitor.onRevealChanged = { callbacks.append($0) }

        monitor.handleFlagsChanged(rawFlags: option)
        let hold = try XCTUnwrap(monitor.holdTask)
        await sleeper.waitForPendingSleeps(1)

        XCTAssertEqual(sleeper.pendingCount, 1)
        monitor.handleFlagsChanged(rawFlags: 0)
        await hold.value

        XCTAssertEqual(sleeper.pendingCount, 0)
        XCTAssertEqual(callbacks, [])
    }

    func testDelayedPressAndHoldRevealsAfterDelay() async throws {
        let sleeper = ManualSleeper()
        let monitor = WorkspaceBarRevealMonitor(modifier: .option, holdMilliseconds: 50) {
            try await sleeper.sleep(for: $0)
        }
        var callbacks: [Bool] = []
        monitor.onRevealChanged = { callbacks.append($0) }

        monitor.handleFlagsChanged(rawFlags: option)
        let hold = try XCTUnwrap(monitor.holdTask)
        await sleeper.waitForPendingSleeps(1)

        XCTAssertEqual(sleeper.requestedDurations, [.milliseconds(50)])
        XCTAssertEqual(callbacks, [])
        sleeper.resumeNext()
        await hold.value

        XCTAssertEqual(callbacks, [true])
    }

    func testStopWhileRevealedEmitsFalse() {
        let monitor = WorkspaceBarRevealMonitor(modifier: .option, holdMilliseconds: 0)
        var callbacks: [Bool] = []
        monitor.onRevealChanged = { callbacks.append($0) }

        monitor.handleFlagsChanged(rawFlags: option)
        monitor.stop()

        XCTAssertEqual(callbacks, [true, false])
    }
}
