// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class LauncherEnvironmentTransferTests: XCTestCase {
    func testReusedTerminalRemovesVariablesMissingFromCapturedEnvironment() async throws {
        let request = LauncherLaunchRequest(
            executable: "/usr/bin/env", arguments: ["-0"], directory: "/private/tmp",
            environment: ["PATH": "/usr/bin:/bin", "OMNIWM_CAPTURED_TEST": "fresh"]
        )
        let stale = [
            "TERM": "xterm-256color",
            "OMNIWM_REMOVED_TEST": "stale",
            "HTTP_PROXY": "http://stale.invalid:8080",
            "https_proxy": "http://stale.invalid:8081",
            "PYTHONPATH": "/stale/python",
            "HOME": "/stale/home"
        ]
        let background = try await LauncherProcess.run(
            executable: request.executable, arguments: request.arguments,
            environment: request.environment, directory: request.directory
        )
        let terminal = try await runTransfer(request, inheriting: stale)
        XCTAssertEqual(background.status, 0)
        XCTAssertEqual(terminal.status, 0)
        var received = environment(in: terminal.output)
        XCTAssertEqual(received.removeValue(forKey: "TERM"), "xterm-256color")
        XCTAssertEqual(received, environment(in: background.output))
    }

    func testReusedTerminalKeepsOnlyFreshTerminalMetadata() async throws {
        let terminal = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "terminal ' \" $HOME; 雪\nvalue",
            "TERM_PROGRAM_VERSION": "1.2.3",
            "TERM_SESSION_ID": "fresh-session",
            "TERMINFO": "/fresh/terminfo",
            "TERMINFO_DIRS": "/fresh/first:/fresh/second",
            "TTY": "/dev/ttys123"
        ]
        var captured = terminal.mapValues { _ in "stale-captured-value" }
        captured["PATH"] = "/usr/bin:/bin"
        captured["OMNIWM_CAPTURED_TEST"] = "captured ' \" $HOME; 雪\nvalue"
        captured["PYTHONPATH"] = ""
        let request = LauncherLaunchRequest(
            executable: "/usr/bin/env", arguments: ["-0"], directory: "/private/tmp", environment: captured
        )
        var inherited = terminal
        inherited["PATH"] = "/stale/path"
        inherited["OMNIWM_CAPTURED_TEST"] = "stale"
        inherited["OMNIWM_REMOVED_TEST"] = "stale"
        inherited["PYTHONPATH"] = "/stale/python"
        let result = try await runTransfer(request, inheriting: inherited)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(
            environment(in: result.output),
            request.terminalEnvironment.merging(terminal) { _, fresh in fresh }
        )
    }

    func testReusedTerminalLeavesMissingMetadataUnset() async throws {
        let request = LauncherLaunchRequest(
            executable: "/usr/bin/env", arguments: ["-0"], directory: "/private/tmp",
            environment: ["PATH": "/usr/bin:/bin", "TERM": "dumb", "TERM_SESSION_ID": "stale-session"]
        )
        let result = try await runTransfer(request, inheriting: [
            "OMNIWM_REMOVED_TEST": "stale", "TERM": "xterm-256color", "COLORTERM": ""
        ])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(environment(in: result.output), [
            "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "COLORTERM": ""
        ])
    }

    func testReusedTerminalDoesNotRunRemovedShellStartupHook() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-hook-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hook = directory.appendingPathComponent("bash-env")
        try Data("export OMNIWM_REMOVED_HOOK_TEST=stale\n".utf8).write(to: hook)
        let request = LauncherLaunchRequest(
            executable: "/bin/bash", arguments: ["--noprofile", "--norc", "-c", "/usr/bin/env -0"],
            directory: directory.path, environment: ["PATH": "/usr/bin:/bin"]
        )
        let background = try await LauncherProcess.run(
            executable: request.executable, arguments: request.arguments,
            environment: request.environment, directory: request.directory
        )
        let terminal = try await runTransfer(request, inheriting: ["BASH_ENV": hook.path])
        XCTAssertEqual(background.status, 0)
        XCTAssertEqual(terminal.status, 0)
        XCTAssertNil(environment(in: background.output)["OMNIWM_REMOVED_HOOK_TEST"])
        XCTAssertNil(environment(in: terminal.output)["OMNIWM_REMOVED_HOOK_TEST"])
        XCTAssertNil(environment(in: terminal.output)["BASH_ENV"])
    }

    private func runTransfer(
        _ request: LauncherLaunchRequest, inheriting environment: [String: String]
    ) async throws -> LauncherProcessResult {
        let transfer = try LauncherEnvironmentTransfer(request: request)
        defer { transfer.cancel() }
        let helper = try request.makeTerminalHelper(holdOutput: false, transfer: transfer)
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }
        let result = try await LauncherProcess.run(
            executable: "/bin/sh", arguments: [helper.path], environment: environment, deadline: 10
        )
        try await transfer.waitForDelivery()
        XCTAssertFalse(FileManager.default.fileExists(atPath: transfer.endpoint))
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.deletingLastPathComponent().path))
        return result
    }

    private func environment(in output: Data) -> [String: String] {
        var values: [String: String] = [:]
        for item in output.split(separator: 0) {
            guard let separator = item.firstIndex(of: 61) else { continue }
            let key = String(decoding: item[..<separator], as: UTF8.self)
            values[key] = String(decoding: item[item.index(after: separator)...], as: UTF8.self)
        }
        return values
    }
}
