// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Dispatch
@testable import OmniWM
import XCTest

@MainActor
final class PreviewCapturePressureTests: XCTestCase {
    func testPressureObserversReceiveWarningCriticalAndNormalAndCanBeRemovedSeparately() {
        let coordinator = PreviewCaptureCoordinator(ownedWindowRegistry: OwnedWindowRegistry())
        var first: [Bool] = []
        var second: [Bool] = []
        let firstObservation = coordinator.addMemoryPressureObserver { first.append($0) }
        let secondObservation = coordinator.addMemoryPressureObserver { second.append($0) }
        XCTAssertFalse(coordinator.isUnderMemoryPressure)

        coordinator.handleMemoryPressure([])
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        coordinator.handleMemoryPressure(.warning)
        XCTAssertTrue(coordinator.isUnderMemoryPressure)
        XCTAssertEqual(first, [true])
        XCTAssertEqual(second, [true])

        coordinator.removeMemoryPressureObserver(firstObservation)
        coordinator.handleMemoryPressure(.critical)
        XCTAssertTrue(coordinator.isUnderMemoryPressure)
        XCTAssertEqual(first, [true])
        XCTAssertEqual(second, [true, true])

        coordinator.handleMemoryPressure(.normal)
        XCTAssertFalse(coordinator.isUnderMemoryPressure)
        XCTAssertEqual(first, [true])
        XCTAssertEqual(second, [true, true, false])
        coordinator.removeMemoryPressureObserver(secondObservation)
        coordinator.handleMemoryPressure(.warning)
        XCTAssertEqual(second, [true, true, false])
    }
}
