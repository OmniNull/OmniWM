// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class SecureInputIndicatorPlacementTests: XCTestCase {
    func testPanelSitsInsideTheBottomRightOfEachDisplay() {
        let visibleFrames = [
            CGRect(x: 0, y: 0, width: 2560, height: 1410),
            CGRect(x: 2560, y: 1440, width: 1920, height: 1080),
            CGRect(x: -1512, y: -982, width: 1512, height: 944)
        ]
        for visibleFrame in visibleFrames {
            for size in [CGSize(width: 44, height: 44), CGSize(width: 380, height: 140)] {
                let frame = SecureInputIndicatorController.panelFrame(size: size, visibleFrame: visibleFrame)
                XCTAssertTrue(visibleFrame.contains(frame), "\(frame) outside \(visibleFrame)")
                XCTAssertEqual(frame.size, size)
                XCTAssertEqual(visibleFrame.maxX - frame.maxX, frame.minY - visibleFrame.minY)
            }
        }
    }
}

@MainActor
final class SecureInputExplanationTests: XCTestCase {
    private let sleeper = SecureInputManualSleeper()
    private var indicator: SecureInputIndicatorController!

    override func setUp() async throws {
        try await super.setUp()
        let sleeper = sleeper
        indicator = SecureInputIndicatorController(
            ownedWindowRegistry: OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator()),
            sleep: { try await sleeper.sleep(for: $0) }
        )
    }

    override func tearDown() async throws {
        indicator.destroy()
        sleeper.resumeAll()
        indicator = nil
        try await super.tearDown()
    }

    func testExplanationWaitsForTheDelayThenHidesWhenSecureInputEnds() async throws {
        XCTAssertTrue(indicator.setIndicated(true))
        let task = try XCTUnwrap(indicator.explanationTask)
        XCTAssertFalse(indicator.isExplanationVisible)

        sleeper.resumeNext()
        await task.value
        XCTAssertEqual(sleeper.requestedDurations, [SecureInputIndicatorController.explanationDelay])
        XCTAssertTrue(indicator.isExplanationVisible)
        XCTAssertNil(indicator.explanationTask)

        XCTAssertTrue(indicator.setIndicated(false))
        XCTAssertFalse(indicator.isExplanationVisible)
    }

    func testSecureInputEndingBeforeTheDelayCancelsTheExplanation() async throws {
        indicator.setIndicated(true)
        let task = try XCTUnwrap(indicator.explanationTask)

        indicator.setIndicated(false)
        sleeper.resumeNext()
        await task.value

        XCTAssertNil(indicator.explanationTask)
        XCTAssertFalse(indicator.isExplanationVisible)
    }

    func testRepeatedIndicationKeepsTheFirstSchedule() throws {
        XCTAssertTrue(indicator.setIndicated(true))
        let first = try XCTUnwrap(indicator.explanationTask)

        XCTAssertFalse(indicator.setIndicated(true))
        XCTAssertEqual(indicator.explanationTask, first)
    }

    func testExplicitRequestShowsImmediatelyOnlyWhileIndicated() {
        indicator.showExplanation()
        XCTAssertFalse(indicator.isExplanationVisible)

        indicator.setIndicated(true)
        indicator.showExplanation()
        XCTAssertTrue(indicator.isExplanationVisible)
        XCTAssertNil(indicator.explanationTask)
    }
}

@MainActor
private final class SecureInputManualSleeper {
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestedDurations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        requestedDurations.append(duration)
        if permits > 0 {
            permits -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        try Task.checkCancellation()
    }

    func resumeNext() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    func resumeAll() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}
