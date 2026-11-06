// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class StopApplicationRevealTests: XCTestCase {
    func testNotificationRequiresNativeReadbackAndObserverIsRemoved() async {
        var hidden = true
        var changed: (@MainActor @Sendable () -> Void)?
        var requests = 0
        var removals = 0
        let requested = expectation(description: "Unhide requested after observation started")
        let reveal = StopApplicationReveal(
            isHidden: { hidden }, requestUnhide: { requests += 1
                requested.fulfill()
                return true
            },
            observe: { changed = $0
                return { removals += 1 }
            }
        )
        let task = Task { await reveal.reveal(deadline: ProcessInfo.processInfo.systemUptime + 10) }
        await fulfillment(of: [requested], timeout: failureBound)
        changed?()
        XCTAssertEqual(removals, 0)
        hidden = false
        changed?()
        let success = await task.value
        XCTAssertTrue(success)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(removals, 1)
        changed?()
        XCTAssertEqual(removals, 1)
    }

    func testAlreadyVisibleAppDoesNotUnhideOrInstallObserver() async {
        let reveal = StopApplicationReveal(
            isHidden: { false }, requestUnhide: { XCTFail()
                return false
            }, observe: { _ in XCTFail()
                return {}
            }
        )
        let success = await reveal.reveal(deadline: ProcessInfo.processInfo.systemUptime + 10)
        XCTAssertTrue(success)
    }

    func testRefusalAndCancellationRemoveObserver() async {
        for refusal in [false, true] {
            var removals = 0
            let requested = expectation(description: "Unhide request")
            let reveal = StopApplicationReveal(
                isHidden: { true }, requestUnhide: { requested.fulfill()
                    return !refusal
                },
                observe: { _ in { removals += 1 } }
            )
            let task = Task { await reveal.reveal(deadline: ProcessInfo.processInfo.systemUptime + 10) }
            await fulfillment(of: [requested], timeout: failureBound)
            if !refusal { task.cancel() }
            let success = await task.value
            XCTAssertFalse(success)
            XCTAssertEqual(removals, 1)
        }
    }

    func testExpiredBudgetDoesNotRequestUnhide() async {
        let reveal = StopApplicationReveal(
            isHidden: { true }, requestUnhide: { XCTFail()
                return true
            }, observe: { _ in XCTFail()
                return {}
            }
        )
        let success = await reveal.reveal(deadline: 0)
        XCTAssertFalse(success)
    }
}
