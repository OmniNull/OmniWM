// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
@testable import OmniWM
import XCTest

final class AppThemeReloaderTests: XCTestCase {
    private var fake: AppThemeFakeEnvironment!

    override func setUp() {
        fake = AppThemeFakeEnvironment()
    }

    private func reload(_ action: AppThemeReloadAction) -> AppThemeReloadOutcome {
        AppThemeReloader(environment: fake.environment).reload(action)
    }

    func testEveryRunningGhosttyGetsSIGUSR2AndNothingIsRun() {
        fake.ghostty = [
            AppThemeGhosttyApp(pid: 10, version: "1.4.0"),
            AppThemeGhosttyApp(pid: 11, version: "1.2.0")
        ]
        let outcome = reload(.ghostty)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.message, String(localized: "Reloaded Ghostty"))
        XCTAssertEqual(fake.signals, [.init(pid: 10, signal: SIGUSR2), .init(pid: 11, signal: SIGUSR2)])
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testAGhosttyThatCannotReloadOnASignalIsNeverSignalled() {
        fake.ghostty = [
            AppThemeGhosttyApp(pid: 10, version: "1.1.3"),
            AppThemeGhosttyApp(pid: 11, version: nil),
            AppThemeGhosttyApp(pid: 12, version: "1.4.0")
        ]
        let outcome = reload(.ghostty)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(fake.signals, [.init(pid: 12, signal: SIGUSR2)])
        XCTAssertEqual(outcome.message, [
            String(localized: "Ghostty 1.1.3 doesn’t reload on a signal; update it, or reload its config with ⌘⇧,"),
            String(
                localized: "OmniWM can’t tell which Ghostty version is running, so it didn’t signal it; reload its config with ⌘⇧,"
            )
        ].joined(separator: " · "))
    }

    func testNoGhosttyRunningIsFine() {
        let outcome = reload(.ghostty)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.message, String(localized: "Ghostty isn’t running; it uses the new theme when it opens"))
        XCTAssertTrue(fake.signals.isEmpty)
    }

    func testAGhosttyThatQuitBeforeTheSignalIsFine() {
        fake.runGhostty()
        fake.signalErrors[AppThemeFakeEnvironment.ghosttyPID] = ESRCH
        XCTAssertTrue(reload(.ghostty).succeeded)
    }

    func testAGhosttySignalThatFailsIsReported() {
        fake.runGhostty()
        fake.signalErrors[AppThemeFakeEnvironment.ghosttyPID] = EPERM
        let outcome = reload(.ghostty)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(
            outcome.message,
            String(localized: "Ghostty didn’t reload") + ": " + String(cString: strerror(EPERM))
        )
    }

    func testSignalReloadStartsWithTheGhosttyThatHandlesSIGUSR2() {
        let first = AppThemeGhosttyApp.signalReloadVersion.map(String.init).joined(separator: ".")
        for version in [first, first + ".0", "1.4.0", "1.10.1", "2.0.0-dev+0a1b2c"] {
            XCTAssertTrue(AppThemeGhosttyApp(pid: 1, version: version).reloadsOnSignal, version)
        }
        for version in ["1.1.3", "1.0.0", "0.9", "tip", ""] {
            XCTAssertFalse(AppThemeGhosttyApp(pid: 1, version: version).reloadsOnSignal, version)
        }
        XCTAssertFalse(AppThemeGhosttyApp(pid: 1, version: nil).reloadsOnSignal)
    }

    func testTheRunningGhosttyVersionIsUnknownOnceItsBundleChangedAfterLaunch() throws {
        let launch = Date.distantPast
        XCTAssertEqual(
            AppThemeGhosttyApp.runningVersion(info: ["CFBundleShortVersionString": "1.4.0"], modified: launch, launched: launch),
            "1.4.0"
        )
        XCTAssertNil(AppThemeGhosttyApp.runningVersion(
            info: ["CFBundleShortVersionString": "1.4.0"],
            modified: Date.now,
            launched: launch
        ))
        XCTAssertNil(AppThemeGhosttyApp.runningVersion(info: nil, modified: launch, launched: launch))
        XCTAssertNil(AppThemeGhosttyApp.runningVersion(
            info: ["CFBundleShortVersionString": "1.4.0"],
            modified: launch,
            launched: nil
        ))
    }
}

extension AppThemeReloaderTests {
    func testKittyAndNeovimAreSignalledWithSIGUSR1AndNothingIsRun() {
        fake.processes = ["kitty": [20, 21], "nvim": [30]]
        XCTAssertTrue(reload(.kitty).succeeded)
        XCTAssertTrue(reload(.neovim).succeeded)
        XCTAssertEqual(fake.signals, [
            .init(pid: 20, signal: SIGUSR1), .init(pid: 21, signal: SIGUSR1), .init(pid: 30, signal: SIGUSR1)
        ])
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testKittyOrNeovimNotRunningIsFine() {
        fake.processes = [:]
        let kitty = reload(.kitty)
        let neovim = reload(.neovim)
        XCTAssertTrue(kitty.succeeded)
        XCTAssertTrue(neovim.succeeded)
        XCTAssertEqual(kitty.message, String(localized: "kitty isn’t running; it uses the new theme when it opens"))
        XCTAssertEqual(
            neovim.message,
            String(localized: "Neovim isn’t running; it loads the new colors when it starts")
        )
        XCTAssertTrue(fake.signals.isEmpty)
    }

    func testAKittyThatQuitBeforeTheSignalIsFineAndOtherFailuresAreReported() {
        fake.processes = ["kitty": [20, 21]]
        fake.signalErrors = [20: ESRCH]
        XCTAssertTrue(reload(.kitty).succeeded)
        fake.signalErrors = [21: EPERM]
        let outcome = reload(.kitty)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.message, String(localized: "kitty didn’t reload") + ": " + String(cString: strerror(EPERM)))
    }

    func testProcessesAreFoundByTheirExactNameForTheRealUserOnly() throws {
        let pid = getpid()
        let name = try XCTUnwrap(AppThemeProcesses.name(of: pid))
        XCTAssertTrue(AppThemeProcesses.list(named: name, realUserID: getuid()).contains(pid))
        XCTAssertFalse(AppThemeProcesses.list(named: name + "x", realUserID: getuid()).contains(pid))
        XCTAssertFalse(AppThemeProcesses.list(named: String(name.dropLast()), realUserID: getuid()).contains(pid))
        XCTAssertFalse(AppThemeProcesses.list(named: name, realUserID: getuid() &+ 1).contains(pid))
    }
}
