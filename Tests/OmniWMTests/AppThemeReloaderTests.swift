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

    private let packaged = Date(timeIntervalSince1970: 0)

    private func makeGhosttyBundle(in folder: URL, executable: Bool = true) throws -> URL {
        let bundle = folder.appendingPathComponent("Ghostty.app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        let info: NSDictionary = ["CFBundleShortVersionString": "1.4.0", "CFBundleExecutable": "ghostty"]
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        var files = [contents.appendingPathComponent("Info.plist")]
        if executable {
            try Data().write(to: contents.appendingPathComponent("MacOS/ghostty"))
            files.append(contents.appendingPathComponent("MacOS/ghostty"))
        }
        for file in files {
            try FileManager.default.setAttributes([.modificationDate: packaged], ofItemAtPath: file.path)
        }
        return bundle
    }

    func testTheRunningGhosttyVersionIsKnownOnlyFromFilesUnchangedSinceItStarted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = try makeGhosttyBundle(in: folder)
        XCTAssertEqual(AppThemeGhosttyApp.runningVersion(bundle: bundle, started: Date.distantFuture), "1.4.0")
        XCTAssertNil(AppThemeGhosttyApp.runningVersion(bundle: bundle, started: packaged))
        let incomplete = try makeGhosttyBundle(in: folder.appendingPathComponent("incomplete"), executable: false)
        XCTAssertNil(AppThemeGhosttyApp.runningVersion(bundle: incomplete, started: Date.distantFuture))
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
        XCTAssertEqual(
            outcome.message,
            String(localized: "kitty didn’t reload") + ": " + String(cString: strerror(EPERM))
        )
    }

    func testEveryProcessIsSignalledAndTheFirstFailureIsReported() {
        let pids: [pid_t] = [20, 21, 22]
        fake.processes = ["kitty": pids]
        fake.signalErrors = [pids[0]: ESRCH, pids[1]: EPERM, pids[2]: EACCES]
        let outcome = reload(.kitty)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(
            outcome.message,
            String(localized: "kitty didn’t reload") + ": " + String(cString: strerror(EPERM))
        )
        XCTAssertEqual(fake.signals, pids.map { .init(pid: $0, signal: SIGUSR1) })
    }

    func testProcessesAreFoundByTheirExactNameForTheRealUserOnly() throws {
        let pid = getpid()
        let name = try XCTUnwrap(AppThemeProcesses.name(of: pid))
        func pids(_ name: String, _ user: uid_t) -> [pid_t] {
            AppThemeProcesses.list(named: name, realUserID: user).map(\.pid)
        }
        XCTAssertTrue(pids(name, getuid()).contains(pid))
        XCTAssertFalse(pids(name + "x", getuid()).contains(pid))
        XCTAssertFalse(pids(String(name.dropLast()), getuid()).contains(pid))
        XCTAssertFalse(pids(name, getuid() &+ 1).contains(pid))
    }

    func testASignalGoesOnlyToTheProcessThatWasListed() throws {
        let existenceCheck: Int32 = 0
        let listed = try XCTUnwrap(AppThemeProcesses.identity(of: getpid()))
        XCTAssertEqual(listed.realUserID, getuid())
        XCTAssertEqual(AppThemeProcesses.signal(listed, existenceCheck), 0)
        let replacements = [
            AppThemeProcess(
                pid: listed.pid,
                startSeconds: listed.startSeconds + 1,
                startMicroseconds: listed.startMicroseconds,
                realUserID: listed.realUserID,
                name: listed.name
            ),
            AppThemeProcess(
                pid: listed.pid,
                startSeconds: listed.startSeconds,
                startMicroseconds: listed.startMicroseconds + 1,
                realUserID: listed.realUserID,
                name: listed.name
            ),
            AppThemeProcess(
                pid: listed.pid,
                startSeconds: listed.startSeconds,
                startMicroseconds: listed.startMicroseconds,
                realUserID: listed.realUserID &+ 1,
                name: listed.name
            ),
            AppThemeProcess(
                pid: listed.pid,
                startSeconds: listed.startSeconds,
                startMicroseconds: listed.startMicroseconds,
                realUserID: listed.realUserID,
                name: listed.name + "x"
            )
        ]
        for replacement in replacements {
            XCTAssertEqual(AppThemeProcesses.signal(replacement, existenceCheck), ESRCH)
        }
    }
}

extension AppThemeReloaderTests {
    private func reply(status: String, diagnostics: [String] = []) -> AppThemeSocketReply {
        let list = diagnostics.map { "\"\($0)\"" }.joined(separator: ",")
        return .line(
            #"{"id":"\#(AppThemeHerdrSocket.requestID)","result":{"type":"config_reload","status":""#
                + status + #"","diagnostics":["# + list + "]}}"
        )
    }

    func testHerdrsSocketIsFoundTheWayHerdrFindsIt() {
        let home = URL(fileURLWithPath: "/Users/someone")
        func path(_ variables: [String: String]) -> String {
            AppThemeHerdrSocket.path(variables: variables, home: home)
        }
        XCTAssertEqual(path([:]), "/Users/someone/.config/herdr/herdr.sock")
        XCTAssertEqual(
            path(["HERDR_SOCKET_PATH": "/run/custom.sock", "HERDR_SESSION": "work"]),
            "/run/custom.sock"
        )
        XCTAssertEqual(path(["HERDR_SESSION": "work"]), "/Users/someone/.config/herdr/sessions/work/herdr.sock")
        XCTAssertEqual(path(["HERDR_SESSION": "default"]), "/Users/someone/.config/herdr/herdr.sock")
        for invalid in [
            "",
            ".",
            "..",
            "../work",
            "a/b",
            "wörk",
            String(repeating: "a", count: AppThemeHerdrSocket.maximumSessionName + 1)
        ] {
            XCTAssertEqual(path(["HERDR_SESSION": invalid]), "/Users/someone/.config/herdr/herdr.sock", invalid)
        }
        XCTAssertEqual(
            path(["XDG_CONFIG_HOME": "/xdg", "HERDR_SESSION": "w-1.x_2"]),
            "/xdg/herdr/sessions/w-1.x_2/herdr.sock"
        )
        for ignored in ["", "relative/config"] {
            XCTAssertEqual(path(["XDG_CONFIG_HOME": ignored]), "/Users/someone/.config/herdr/herdr.sock", ignored)
            XCTAssertEqual(
                AppThemeOutputPolicy.live(environment: ["XDG_CONFIG_HOME": ignored], home: home).configHome.path,
                "/Users/someone/.config"
            )
        }
    }

    func testLocalHerdrIsReloadedThroughItsSocketAndNothingIsRun() {
        fake.variables = ["HOME": "/Users/someone"]
        let outcome = reload(.herdr(savedMachines: false))
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.message, String(localized: "Reloaded herdr"))
        XCTAssertEqual(fake.events, ["herdr server.reload_config"])
        XCTAssertEqual(fake.herdrSockets, ["/Users/someone/.config/herdr/herdr.sock"])
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testHerdrNotRunningIsFine() {
        fake.herdrReply = .notRunning
        let outcome = reload(.herdr(savedMachines: false))
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.message, String(localized: "herdr isn’t running; it uses the new colors when it starts"))
    }

    func testHerdrsOwnReloadResultIsShown() {
        fake.herdrReply = reply(status: "partial", diagnostics: ["unknown key theme.custom.foo"])
        let partial = reload(.herdr(savedMachines: false))
        XCTAssertTrue(partial.succeeded)
        XCTAssertEqual(
            partial.message,
            String(localized: "Reloaded herdr with warnings") + ": unknown key theme.custom.foo"
        )
        fake.herdrReply = reply(status: "failed", diagnostics: ["config.toml: expected a string"])
        let failed = reload(.herdr(savedMachines: false))
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(
            failed.message,
            String(localized: "herdr couldn’t apply its config") + ": config.toml: expected a string"
        )
        fake.herdrReply = .line(
            #"{"id":"\#(AppThemeHerdrSocket.requestID)","error":{"code":"denied","message":"not allowed"}}"#
        )
        let refused = reload(.herdr(savedMachines: false))
        XCTAssertFalse(refused.succeeded)
        XCTAssertEqual(refused.message, String(localized: "herdr didn’t reload") + ": not allowed")
        fake.herdrReply = .failed("timed out")
        XCTAssertEqual(
            reload(.herdr(savedMachines: false)).message,
            String(localized: "herdr didn’t reload") + ": timed out"
        )
        fake.herdrReply = .line("not json")
        XCTAssertFalse(reload(.herdr(savedMachines: false)).succeeded)
    }

    func testLocalHerdrNeedsNoHerdrCommand() {
        fake.executables = [:]
        let outcome = reload(.herdr(savedMachines: false))
        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(fake.calls.isEmpty)
    }
}

extension AppThemeReloaderTests {
    private var listCommand: String {
        AppThemeFakeEnvironment.herdrExecutable + " machine list"
    }

    private func listMachines(_ labels: [String]) {
        let machines = labels.map { #"{"label":"\#($0)","enabled":true}"# }.joined(separator: ",")
        fake.responses[listCommand] = AppThemeCommandResult(status: 0, output: "[" + machines + "]")
    }

    func testSavedMachineReloadNeedsTheHerdrExecutable() {
        fake.executables = [:]
        let outcome = reload(.herdr(savedMachines: true))
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.message, String(localized: "Reloaded herdr") + " · " + String(
            localized: "saved machines need herdr in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin"
        ))
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testSavedMachinesMustBeListedSuccessfullyAndDecoded() {
        for response in [
            AppThemeCommandResult(status: 1, output: "[]"),
            AppThemeCommandResult(status: 0, output: "[]", timedOut: true),
            AppThemeCommandResult(status: 0, output: "not json"),
            AppThemeCommandResult(status: 0, output: "{}")
        ] {
            fake = AppThemeFakeEnvironment()
            fake.responses[listCommand] = response
            let outcome = reload(.herdr(savedMachines: true))
            XCTAssertFalse(outcome.succeeded, "\(response)")
            XCTAssertEqual(
                outcome.message,
                String(localized: "Reloaded herdr") + " · " + String(localized: "saved machines couldn’t be listed")
            )
            XCTAssertEqual(fake.calls, [.init(
                executable: AppThemeFakeEnvironment.herdrExecutable,
                arguments: ["machine", "list", "--json"]
            )])
        }
    }

    func testAnEmptySavedMachineListIsSuccessful() {
        listMachines([])
        let outcome = reload(.herdr(savedMachines: true))
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.message, String(localized: "Reloaded herdr"))
        XCTAssertEqual(fake.calls.map(\.arguments), [["machine", "list", "--json"]])
    }

    func testEveryRequestedSavedMachineMustReloadSuccessfully() {
        let labels = ["studio", "server"]
        for failures in [[], [labels[0]], labels] {
            fake = AppThemeFakeEnvironment()
            listMachines(labels)
            for label in failures {
                fake.responses[AppThemeFakeEnvironment.herdrExecutable + " --machine " + label] =
                    AppThemeCommandResult(status: 1, output: "unavailable")
            }
            let outcome = reload(.herdr(savedMachines: true))
            let successes = labels.count - failures.count
            XCTAssertEqual(outcome.succeeded, failures.isEmpty)
            XCTAssertEqual(outcome.message, String(localized: "Reloaded herdr") + " · " + String(
                localized: "\(successes) of \(labels.count) saved machines reloaded"
            ))
            XCTAssertEqual(fake.calls.dropFirst().map(\.arguments).sorted { $0[1] < $1[1] }, labels.sorted().map {
                ["--machine", $0, "server", "reload-config"]
            })
        }
    }

    func testSuccessfulSavedMachineReloadsDoNotHideALocalFailure() {
        listMachines(["studio"])
        fake.herdrReply = .failed("unavailable")
        XCTAssertFalse(reload(.herdr(savedMachines: true)).succeeded)
    }

    func testAFailedSavedMachineReloadStaysPendingAndRetriesWithoutAFileChange() throws {
        let sandbox = try AppThemeSandbox()
        defer { sandbox.remove() }
        let label = "studio"
        listMachines([label])
        let command = AppThemeFakeEnvironment.herdrExecutable + " --machine " + label
        fake.responses[command] = AppThemeCommandResult(status: 1, output: "unavailable")
        var settings = SettingsExport.AppTheming()
        settings.setEnabled(.herdr, true)
        settings.herdr.reloadSavedMachines = true
        let job = AppThemeJob(
            palette: AppThemeFixtures.palette,
            dark: true,
            appearanceChanged: false,
            targets: settings.targets(configHome: sandbox.policy.configHome)
        )
        let first = sandbox.engine(fake).run(job)
        XCTAssertEqual(first.results[AppThemeBuiltIn.herdr.id]?.reloadFailed, true)
        XCTAssertEqual(try sandbox.store.load().reloadPending, [AppThemeBuiltIn.herdr.id])
        let callsBeforeRetry = fake.calls.count
        fake.responses[command] = AppThemeCommandResult(status: 0, output: "")
        let retry = sandbox.engine(fake).run(job)
        XCTAssertEqual(retry.results[AppThemeBuiltIn.herdr.id]?.outcome, .unchanged)
        XCTAssertEqual(retry.results[AppThemeBuiltIn.herdr.id]?.reloadFailed, false)
        XCTAssertTrue(try sandbox.store.load().reloadPending.isEmpty)
        XCTAssertEqual(fake.calls.dropFirst(callsBeforeRetry).map(\.arguments), [
            ["machine", "list", "--json"], ["--machine", label, "server", "reload-config"]
        ])
    }
}
