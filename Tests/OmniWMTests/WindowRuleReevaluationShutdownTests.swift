// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowRuleReevaluationShutdownTests: XCTestCase {
    func testSupersedingRunRetainsOutstandingWindowAndPIDTargets() async {
        let firstTargets: Set<WindowRuleReevaluationTarget> = [
            .window(WindowToken(pid: 696_301, windowId: 696_302)),
            .window(WindowToken(pid: 696_301, windowId: 696_303)),
            .pid(696_304)
        ]
        let nextTarget = WindowRuleReevaluationTarget.window(WindowToken(pid: 696_305, windowId: 696_306))
        let finalTarget = WindowRuleReevaluationTarget.pid(696_307)
        let controller = WindowAdmissionTestSupport.controller(prefix: "RuleSupersession")
        defer { controller.serviceLifecycleManager.stop() }
        let firstStarted = expectation(description: "First evaluation suspended")
        let firstFinished = expectation(description: "Cancelled evaluation returned")
        let successorFinished = expectation(description: "Successor evaluated all outstanding targets")
        let finalFinished = expectation(description: "Completed targets cleared")
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        var runs = 0
        let scheduler = WindowRuleReevaluationScheduler(controller: controller) { _, targets in
            runs += 1
            switch runs {
            case 1:
                XCTAssertEqual(targets, firstTargets)
                firstStarted.fulfill()
                _ = await gate.wait()
                XCTAssertTrue(Task.isCancelled)
                firstFinished.fulfill()
            case 2:
                XCTAssertEqual(targets, firstTargets.union([nextTarget]))
                successorFinished.fulfill()
            case 3:
                XCTAssertEqual(targets, [finalTarget])
                finalFinished.fulfill()
            default:
                XCTFail("Unexpected evaluation")
            }
            return WindowRuleReevaluationOutcome(
                resolvedAnyTarget: true, evaluatedAnyWindow: true,
                relayoutNeeded: false, stale: Task.isCancelled
            )
        }
        defer { scheduler.reset() }
        scheduler.schedule(targets: firstTargets)
        await fulfillment(of: [firstStarted], timeout: failureBound)
        scheduler.schedule(targets: [nextTarget])
        await fulfillment(of: [successorFinished], timeout: failureBound)
        gate.resume()
        await fulfillment(of: [firstFinished], timeout: failureBound)
        scheduler.schedule(targets: [finalTarget])
        await fulfillment(of: [finalFinished], timeout: failureBound)
        XCTAssertEqual(runs, 3)
    }

    func testResetCancelsReevaluationAlreadyAwaitingNativeFacts() async {
        let controller = WindowAdmissionTestSupport.controller(prefix: "RuleShutdown")
        defer { controller.serviceLifecycleManager.stop() }
        let started = expectation(description: "Rule evaluation waiting for native facts")
        let finished = expectation(description: "Cancelled evaluation observes reset")
        let replacementFinished = expectation(description: "Reset discards old targets")
        var release: CheckedContinuation<Void, Never>?
        var cancelled = false
        let scheduler = WindowRuleReevaluationScheduler(controller: controller) { _, targets in
            if targets.contains(.pid(696_302)) {
                XCTAssertEqual(targets, [.pid(696_302)])
                replacementFinished.fulfill()
                return WindowRuleReevaluationOutcome(
                    resolvedAnyTarget: true, evaluatedAnyWindow: false,
                    relayoutNeeded: false, stale: false
                )
            }
            await withCheckedContinuation { release = $0
                started.fulfill()
            }
            cancelled = Task.isCancelled
            finished.fulfill()
            return WindowRuleReevaluationOutcome(
                resolvedAnyTarget: false,
                evaluatedAnyWindow: false,
                relayoutNeeded: false,
                stale: true
            )
        }
        scheduler.schedule(targets: [.pid(696_301)])
        await fulfillment(of: [started], timeout: failureBound)
        scheduler.reset()
        release?.resume()
        await fulfillment(of: [finished], timeout: failureBound)
        XCTAssertTrue(cancelled)
        scheduler.schedule(targets: [.pid(696_302)])
        await fulfillment(of: [replacementFinished], timeout: failureBound)
        scheduler.reset()
    }
}
