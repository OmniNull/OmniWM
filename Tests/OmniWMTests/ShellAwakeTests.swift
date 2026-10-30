// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import IOKit.pwr_mgt
@testable import OmniWM
import XCTest

@MainActor
final class ShellAwakeTests: XCTestCase {
    @MainActor
    private struct Deadline {
        let duration: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
    }

    @MainActor
    private final class Environment {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var deadlines: [Deadline] = []
        var acquisitions: [IOPMAssertionID] = []
        var releases: [IOPMAssertionID] = []
        var assertionAvailable = true

        func manager() -> SleepPreventionManager {
            SleepPreventionManager(
                now: { self.now },
                scheduleDeadline: { duration, action in
                    let index = self.deadlines.count
                    self.deadlines.append(Deadline(duration: duration, action: action))
                    return { self.deadlines[index].cancelled = true }
                },
                createAssertion: {
                    guard self.assertionAvailable else { return nil }
                    let id = IOPMAssertionID(self.acquisitions.count + 1)
                    self.acquisitions.append(id)
                    return id
                },
                releaseAssertion: { self.releases.append($0) },
                observeWorkspace: false
            )
        }

        func fire(_ index: Int) {
            now = now.addingTimeInterval(deadlines[index].duration)
            deadlines[index].action()
        }
    }

    func testAwakeCommandsRequireOneBoundedFiniteDuration() {
        XCTAssertEqual(ShellAwakeCommand(words: ["awake", "on"]), .on)
        XCTAssertEqual(ShellAwakeCommand(words: ["awake", "off"]), .off)
        XCTAssertEqual(ShellAwakeCommand(words: ["awake", "15"]), .timed(minutes: 15))
        XCTAssertEqual(ShellAwakeCommand(words: ["awake", "0.5"]), .timed(minutes: 0.5))
        XCTAssertEqual(ShellAwakeCommand(words: ["awake", "1440"]), .timed(minutes: 1440))
        for words in [
            [], ["awake"], ["on"], ["awake", "on", "now"], ["awake", "0"], ["awake", "-1"],
            ["awake", "nan"], ["awake", "inf"], ["awake", "1440.1"], ["awake", "later"]
        ] {
            XCTAssertNil(ShellAwakeCommand(words: words), "\(words)")
        }
        XCTAssertEqual(ShellSessionCommand.allCases.map(\.rawValue), ["lock", "sleep", "logout", "restart", "shutdown"])
        XCTAssertNil(ShellSessionCommand(words: ["awake", "on"]))
    }

    func testShellExpiryKeepsTheSettingsAssertionAndPublishesOff() {
        let environment = Environment()
        let manager = environment.manager()
        var snapshots: [ShellAwake] = []
        manager.subscribeAwake { snapshots.append($0) }
        manager.preventSleep()
        manager.perform(.timed(minutes: 15))
        XCTAssertEqual(manager.awake, ShellAwake(on: true, until: 1_000_900))
        XCTAssertEqual(environment.acquisitions, [1])
        XCTAssertEqual(environment.deadlines.map(\.duration), [900])
        environment.fire(0)
        XCTAssertEqual(manager.awake, ShellAwake(on: false, until: nil))
        XCTAssertEqual(environment.releases, [])
        XCTAssertEqual(snapshots, [
            ShellAwake(on: false, until: nil), ShellAwake(on: true, until: 1_000_900),
            ShellAwake(on: false, until: nil)
        ])
        manager.allowSleep()
        XCTAssertEqual(environment.releases, [1])
    }

    func testShellReasonAloneExpiresOnceAndReleasesTheAssertion() {
        let environment = Environment()
        let manager = environment.manager()
        manager.perform(.timed(minutes: 0.5))
        XCTAssertEqual(environment.acquisitions, [1])
        XCTAssertEqual(environment.releases, [])
        environment.fire(0)
        XCTAssertEqual(environment.releases, [1])
        environment.deadlines[0].action()
        XCTAssertEqual(environment.releases, [1])
        XCTAssertFalse(manager.awake.on)
    }

    func testOffAndRetargetCancelDeadlinesAndStaleCallbacksCannotClearANewReason() {
        let environment = Environment()
        let manager = environment.manager()
        manager.perform(.timed(minutes: 15))
        manager.perform(.timed(minutes: 30))
        XCTAssertTrue(environment.deadlines[0].cancelled)
        environment.deadlines[0].action()
        XCTAssertEqual(manager.awake.until, 1_001_800)
        manager.perform(.off)
        XCTAssertTrue(environment.deadlines[1].cancelled)
        XCTAssertEqual(environment.releases, [1])
        manager.perform(.on)
        environment.deadlines[1].action()
        XCTAssertEqual(manager.awake, ShellAwake(on: true, until: nil))
        XCTAssertEqual(environment.acquisitions, [1, 2])
        manager.perform(.off)
        XCTAssertEqual(environment.releases, [1, 2])
    }

    func testIndependentSubscriptionsAndSessionActivityPreserveTheShellReason() {
        let environment = Environment()
        let manager = environment.manager()
        var first: [ShellAwake] = []
        var second: [ShellAwake] = []
        let token = manager.subscribeAwake { first.append($0) }
        manager.subscribeAwake { second.append($0) }
        manager.perform(.on)
        manager.setSessionActive(false)
        XCTAssertEqual(environment.releases, [1])
        XCTAssertTrue(manager.awake.on)
        manager.setSessionActive(true)
        XCTAssertEqual(environment.acquisitions, [1, 2])
        manager.removeAwakeSubscription(token)
        manager.perform(.off)
        XCTAssertEqual(first.map(\.on), [false, true])
        XCTAssertEqual(second.map(\.on), [false, true, false])
        XCTAssertEqual(environment.releases, [1, 2])
    }

    func testSettingsOffCannotReleaseAnActiveShellReason() {
        let environment = Environment()
        let manager = environment.manager()
        manager.preventSleep()
        manager.perform(.on)
        manager.allowSleep()
        XCTAssertEqual(environment.acquisitions, [1])
        XCTAssertEqual(environment.releases, [])
        manager.perform(.off)
        XCTAssertEqual(environment.releases, [1])
    }

    func testInvalidDirectDurationsDoNotCancelTheCurrentReason() {
        let environment = Environment()
        let manager = environment.manager()
        manager.perform(.timed(minutes: 15))
        for minutes in [0, -1, .nan, .infinity, 1441] {
            manager.perform(.timed(minutes: minutes))
        }
        XCTAssertEqual(manager.awake.until, 1_000_900)
        XCTAssertEqual(environment.deadlines.count, 1)
        XCTAssertFalse(environment.deadlines[0].cancelled)
        manager.perform(.off)
    }

    func testAReleasedManagerCancelsItsDeadlineAndAssertion() {
        let environment = Environment()
        var manager: SleepPreventionManager? = environment.manager()
        manager?.perform(.timed(minutes: 15))
        manager = nil
        XCTAssertTrue(environment.deadlines[0].cancelled)
        XCTAssertEqual(environment.releases, [1])
    }

    func testUnavailableAssertionsLeaveTheReasonRequestedAndNeverReleaseAnUnknownAssertion() {
        let environment = Environment()
        let manager = environment.manager()
        environment.assertionAvailable = false
        manager.perform(.on)
        XCTAssertTrue(manager.awake.on)
        XCTAssertEqual(environment.acquisitions, [])
        manager.perform(.off)
        XCTAssertEqual(environment.releases, [])
        environment.assertionAvailable = true
        manager.perform(.on)
        XCTAssertEqual(environment.acquisitions, [1])
        manager.perform(.off)
        XCTAssertEqual(environment.releases, [1])
    }
}
