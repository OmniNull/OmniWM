// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellNotificationDismissAllSessionTests: XCTestCase {
    private func requests() -> [ShellNotificationActionRequest] {
        let first = UUID()
        let sibling = UUID()
        let other = UUID()
        return [
            .init(bundle: "com.example.First", id: first, peers: [first, sibling], operation: .dismiss),
            .init(bundle: "com.example.Second", id: other, peers: [other], operation: .dismiss),
            .init(bundle: "com.example.First", id: sibling, peers: [first, sibling], operation: .dismiss)
        ]
    }

    func testPartialFailuresContinueInOrderWithinOneHistoryLifetime() {
        let requests = requests()
        var events: [String] = []
        var dismissed: [ShellNotificationActionRequest] = []
        let outcome = ShellNotificationDismissAll.perform(
            requests,
            begin: {
                events.append("begin")
                return nil
            },
            dismiss: { request in
                dismissed.append(request)
                events.append("dismiss:\(request.id)")
                return dismissed.count == 2 ? .notFound : .dispatched
            },
            finish: { outcome in
                events.append("finish:\(outcome.rawValue)")
                return outcome
            },
            progress: { events.append("progress:\($0.rawValue)") }
        )
        XCTAssertEqual(outcome, .dispatched)
        XCTAssertEqual(dismissed, requests)
        XCTAssertEqual(events, [
            "begin", "dismiss:\(requests[0].id)", "progress:dispatched",
            "dismiss:\(requests[1].id)", "progress:notFound",
            "dismiss:\(requests[2].id)", "progress:dispatched", "finish:dispatched"
        ])
    }

    func testBeginFailureStillFinishesWithoutDismissingAnyItem() {
        var events: [String] = []
        let outcome = ShellNotificationDismissAll.perform(
            requests(),
            begin: {
                events.append("begin")
                return .denied
            },
            dismiss: { _ in
                events.append("dismiss")
                return .dispatched
            },
            finish: { outcome in
                events.append("finish:\(outcome.rawValue)")
                return outcome
            },
            progress: { events.append("progress:\($0.rawValue)") }
        )
        XCTAssertEqual(outcome, .denied)
        XCTAssertEqual(events, ["begin", "finish:denied"])
    }

    func testCancellationAfterProgressStopsBeforeNextItemAndFinishesHistory() async {
        let requests = requests()
        let task = Task { @MainActor in
            var events: [String] = []
            let outcome = ShellNotificationDismissAll.perform(
                requests,
                begin: {
                    events.append("begin")
                    return nil
                },
                dismiss: { request in
                    events.append("dismiss:\(request.id)")
                    return .dispatched
                },
                finish: { outcome in
                    events.append("finish:\(outcome.rawValue)")
                    return outcome
                },
                progress: { outcome in
                    events.append("progress:\(outcome.rawValue)")
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
            return (outcome, events)
        }
        let (outcome, events) = await task.value
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(events, [
            "begin", "dismiss:\(requests[0].id)", "progress:dispatched", "finish:cancelled"
        ])
    }

    func testAlreadyCancelledTaskPerformsNoNativeSessionWork() async {
        let requests = requests()
        let task = Task { @MainActor in
            var events: [String] = []
            let outcome = ShellNotificationDismissAll.perform(
                requests,
                begin: {
                    events.append("begin")
                    return nil
                },
                dismiss: { _ in
                    events.append("dismiss")
                    return .dispatched
                },
                finish: { outcome in
                    events.append("finish:\(outcome.rawValue)")
                    return outcome
                },
                progress: { events.append("progress:\($0.rawValue)") }
            )
            return (outcome, events)
        }
        task.cancel()
        let (outcome, events) = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(events.isEmpty)
    }

    func testHistoryCleanupOutcomeCannotBeReplacedWithAllClearSuccess() {
        var progress: [ShellNotificationActionOutcome] = []
        var finishes: [ShellNotificationActionOutcome] = []
        let requests = requests()
        let outcome = ShellNotificationDismissAll.perform(
            requests,
            begin: { nil },
            dismiss: { _ in .dispatched },
            finish: { outcome in
                finishes.append(outcome)
                return .dispatchedPanelOpen
            },
            progress: { progress.append($0) }
        )
        XCTAssertEqual(progress, Array(repeating: .dispatched, count: requests.count))
        XCTAssertEqual(finishes, [.dispatched])
        XCTAssertEqual(outcome, .dispatchedPanelOpen)
    }

    func testClosedHistoryStopsAfterOneFailureAndFinishesOnce() {
        let requests = requests()
        for failedIndex in requests.indices {
            var resolved: [ShellNotificationActionRequest] = []
            var progress: [ShellNotificationActionOutcome] = []
            var finishes: [ShellNotificationActionOutcome] = []
            let outcome = ShellNotificationDismissAll.perform(
                requests,
                begin: { nil },
                dismiss: { request in
                    resolved.append(request)
                    return resolved.count == failedIndex + 1 ? .historyClosed : .dispatched
                },
                finish: { result in
                    finishes.append(result)
                    return result
                },
                progress: { progress.append($0) }
            )
            XCTAssertEqual(resolved, Array(requests.prefix(failedIndex + 1)))
            XCTAssertEqual(progress, Array(repeating: .dispatched, count: failedIndex) + [.historyClosed])
            XCTAssertEqual(finishes, [.historyClosed])
            XCTAssertEqual(outcome, .historyClosed)
        }
    }

    func testDismissReadsActionsAndPressesTheSameTargetAfterOneResolution() throws {
        let target = UUID()
        let close = "Name:Close\nTarget:close"
        var resolutions = 0
        var actionTargets: [UUID] = []
        var pressedTargets: [UUID] = []
        var pressedActions: [String] = []
        let outcome = try ShellNotificationAction.dismiss(
            resolve: {
                resolutions += 1
                return resolutions == 1 ? target : UUID()
            },
            actions: { resolved in
                actionTargets.append(resolved)
                return ["Name:Show Details\nTarget:details", close]
            },
            press: { resolved, action in
                pressedTargets.append(resolved)
                pressedActions.append(action)
                return true
            }
        )
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(actionTargets, [target])
        XCTAssertEqual(pressedTargets, [target])
        XCTAssertEqual(pressedActions, [close])
        XCTAssertEqual(outcome, .dispatched)
    }

    func testMissingOrAmbiguousAdvertisedCloseNeverPresses() throws {
        let close = "Name:Close\nTarget:close"
        let cases: [([String], ShellNotificationActionOutcome)] = [
            (["Name:Close All\nTarget:clear"], .unsupported),
            ([close, close], .ambiguous)
        ]
        for (advertised, expected) in cases {
            var resolutions = 0
            var presses = 0
            let outcome = try ShellNotificationAction.dismiss(
                resolve: {
                    resolutions += 1
                    return UUID()
                },
                actions: { _ in advertised },
                press: { _, _ in
                    presses += 1
                    return true
                }
            )
            XCTAssertEqual(resolutions, 1)
            XCTAssertEqual(presses, 0)
            XCTAssertEqual(outcome, expected)
        }
    }

    func testRejectedCloseDoesNotReportDispatch() throws {
        let outcome = try ShellNotificationAction.dismiss(
            resolve: { UUID() },
            actions: { _ in ["Name:Close\nTarget:close"] },
            press: { _, _ in false }
        )
        XCTAssertEqual(outcome, .failed)
    }

    func testStackClearPressesTheOneAdvertisedClearAll() {
        let clearAll = "Name:Clear All\nTarget:clear"
        var pressed: [String] = []
        let cleared = ShellNotificationAction.clearStack(
            actions: { ["Name:Show Details\nTarget:details", clearAll] },
            press: { action in
                pressed.append(action)
                return true
            }
        )
        XCTAssertTrue(cleared)
        XCTAssertEqual(pressed, [clearAll])
    }

    func testRefusedStackClearLeavesTheStackToTheBannerPath() {
        let clearAll = "Name:Clear All\nTarget:clear"
        let cases: [(actions: [String]?, accepts: Bool, presses: Int)] = [
            (nil, true, 0),
            (["Name:Clear All Later\nTarget:other"], true, 0),
            ([clearAll, clearAll], true, 0),
            ([clearAll], false, 1)
        ]
        for (advertised, accepts, expectedPresses) in cases {
            var presses = 0
            let cleared = ShellNotificationAction.clearStack(
                actions: { advertised },
                press: { _ in
                    presses += 1
                    return accepts
                }
            )
            XCTAssertFalse(cleared)
            XCTAssertEqual(presses, expectedPresses)
        }
    }

    func testCancellationDuringTheActionReadSendsNoStackClear() {
        struct Cancelled: Error {}
        var cancelled = false
        var sent = 0
        XCTAssertThrowsError(try ShellNotificationAction.clearStack(
            actions: {
                cancelled = true
                return ["Name:Clear All\nTarget:clear"]
            },
            press: { _ in
                if cancelled { throw Cancelled() }
                sent += 1
                return true
            }
        )) { XCTAssertTrue($0 is Cancelled) }
        XCTAssertEqual(sent, 0)
    }
}
