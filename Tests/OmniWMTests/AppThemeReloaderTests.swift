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
