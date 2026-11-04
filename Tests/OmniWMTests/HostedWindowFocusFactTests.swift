// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
@testable import OmniWM
import XCTest

@MainActor
final class HostedWindowFocusFactTests: XCTestCase {
    func testOurOwnProcessIsReadBeforeTheCallReturnsAndOtherAppsWaitForTheirThread() {
        let resolver = FactResolver()
        defer { resolver.stop() }
        func resolve(_ pid: pid_t) -> Bool {
            resolver.resolveActivationFacts(
                pid: pid, source: .workspaceDidActivateApplication, origin: .external, observationGeneration: 1
            )
        }

        XCTAssertTrue(resolve(getpid()))
        XCTAssertEqual(resolver.activationRequestsInFlight, 0)

        let otherApp = getppid()
        XCTAssertNotEqual(otherApp, getpid())
        XCTAssertTrue(resolve(otherApp))
        XCTAssertEqual(resolver.activationRequestsInFlight, 1)
    }
}
