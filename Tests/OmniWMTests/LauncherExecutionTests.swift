// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
@testable import OmniWM
import TOML
import XCTest

@MainActor
final class LauncherExecutionTests: XCTestCase {
    func testExplicitShellCannotSilentlyUseAnotherExecutable() {
        XCTAssertThrowsError(try LauncherPaths.shell(.fish, executable: "/bin/zsh"))
        XCTAssertNoThrow(try LauncherPaths.shell(.zsh, executable: "/bin/zsh"))
    }

    func testSystemLoginShellFallsBackToZshForAnUnrecognizedShell() throws {
        let (kind, path) = try LauncherPaths.loginShell("/bin/dash")
        XCTAssertEqual(kind, .zsh)
        XCTAssertEqual(path, "/bin/zsh")
    }

    func testSystemLoginShellThrowsWhenNothingIsExecutable() {
        XCTAssertThrowsError(try LauncherPaths.loginShell(nil))
        XCTAssertThrowsError(try LauncherPaths.loginShell("/no/such/shell"))
    }

    func testLauncherEntryDecodesFromAHandwrittenTableMissingFields() throws {
        let toml = Data("""
        name = "Build"
        command = "swift build"
        """.utf8)
        let decoded = try TOMLDecoder().decode(LauncherEntry.self, from: toml)
        XCTAssertEqual(decoded.name, "Build")
        XCTAssertEqual(decoded.command, "swift build")
        XCTAssertEqual(decoded.kind, .command)
    }

    func testSavedCommandKeepsTheCapturedPathWhenLoginStartupResetsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-path-\(UUID())")
        let tools = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("export PATH=/usr/bin:/bin\n".utf8).write(to: root.appendingPathComponent(".bash_profile"))
        let tool = tools.appendingPathComponent("omniwm-review-tool")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let result = try await LauncherProcess.run(
            executable: "/bin/bash",
            arguments: LauncherShell.bash.commandArguments("omniwm-review-tool", interactive: false),
            environment: ["PATH": tools.path + ":/usr/bin:/bin", "HOME": root.path]
        )
        XCTAssertEqual(result.status, 0, String(decoding: result.output, as: UTF8.self))
    }

    func testRefreshReloadsEveryCachedShellEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-cache-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let override = root.appendingPathComponent("zsh")
        try FileManager.default.createSymbolicLink(at: override, withDestinationURL: URL(fileURLWithPath: "/bin/zsh"))
        let previousZDOTDIR = ProcessInfo.processInfo.environment["ZDOTDIR"]
        setenv("ZDOTDIR", root.path, 1)
        setenv("OMNIWM_LAUNCHER_MARKER", "old", 1)
        defer {
            unsetenv("OMNIWM_LAUNCHER_MARKER")
            if let previousZDOTDIR { setenv("ZDOTDIR", previousZDOTDIR, 1) } else { unsetenv("ZDOTDIR") }
        }
        var global = LauncherConfiguration()
        global.shell = .zsh
        global.shellExecutable = "/bin/zsh"
        var entry = global
        entry.shellExecutable = override.path
        let cache = LauncherEnvironmentCache(helperExecutable: try LauncherHelperTestSupport.executable)
        _ = try await cache.environment(for: global)
        _ = try await cache.environment(for: entry)
        setenv("OMNIWM_LAUNCHER_MARKER", "new", 1)
        _ = try await cache.environment(for: global, refresh: true)
        let reloaded = try await cache.environment(for: entry)
        XCTAssertEqual(reloaded.values["OMNIWM_LAUNCHER_MARKER"], "new")
    }

    func testConfigurationRoundtripIncludesSavedEntriesAndShells() throws {
        var export = SettingsExport.defaults()
        var entry = LauncherEntry()
        entry.kind = .script
        entry.name = "Build"
        entry.path = "~/scripts/build.nu"
        entry.arguments = ["a b", "x'y", "雪"]
        entry.shell = .nushell
        entry.terminal = .builtIn
        export.launcher.entries = [entry]
        export.launcher.appFolders = ["~/Tools"]
        export.launcher.cliFolders = ["~/bin"]
        export.launcher.shell = .fish
        export.launcher.shellExecutable = "/custom/fish"
        export.launcher.terminal = .ghostty
        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        XCTAssertEqual(decoded.launcher, export.launcher)
    }

    func testProcessReportsFailureAndDrainsBoundedOutput() async throws {
        let outputLimit = Int(getpagesize())
        let large = String(repeating: "a", count: outputLimit * 2)
        let result = try await LauncherProcess.run(
            executable: "/usr/bin/printf", arguments: ["%s", large], environment: [:], outputLimit: outputLimit
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, outputLimit)
        XCTAssertTrue(result.truncated)
        let failure = try await LauncherProcess.run(
            executable: "/bin/sh", arguments: ["-c", "printf failure >&2; exit 7"], environment: [:]
        )
        XCTAssertEqual(failure.status, 7)
        XCTAssertEqual(String(decoding: failure.output, as: UTF8.self), "failure")
    }

    func testProcessDeadlineReportsFailure() async throws {
        let fifo = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-blocked-\(UUID())")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        defer { try? FileManager.default.removeItem(at: fifo) }
        do {
            _ = try await LauncherProcess.run(
                executable: "/bin/cat", arguments: [fifo.path], environment: [:], deadline: 0
            )
            XCTFail("An unfinished process must not succeed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("in time"))
        }
    }

    func testDetachedChildDoesNotKeepParentRunOpen() async throws {
        let fifo = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-child-\(UUID())")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        defer { try? FileManager.default.removeItem(at: fifo) }
        let result = try await LauncherProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "/bin/cat \(LauncherHelperTestSupport.quote(fifo.path)) & printf '%s' $!"],
            environment: ["PATH": "/usr/bin:/bin"], deadline: failureBound
        )
        let pid = try XCTUnwrap(Int32(String(decoding: result.output, as: UTF8.self)))
        defer { _ = kill(pid, SIGTERM) }
        XCTAssertEqual(result.status, 0)
    }

    func testDeadlineReapsProcessThatIgnoresTermination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-deadline-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("pid")
        let fifo = root.appendingPathComponent("blocked")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        do {
            _ = try await LauncherProcess.run(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "trap '' TERM; printf '%s' $$ > \(LauncherHelperTestSupport.quote(file.path)); exec /bin/cat \(LauncherHelperTestSupport.quote(fifo.path))"
                ],
                environment: [:], deadline: 1
            )
            XCTFail("The deadline must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("in time"))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: file, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testTerminalHelperPreservesArgumentsDirectoryAndExitStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("launcher ' 雪 \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let arguments = ["a b", "x'y", "\"quoted\"", "$HOME; false", "雪", "line\nbreak"]
        let request = LauncherLaunchRequest(
            executable: "/usr/bin/printf", arguments: ["%s\\0"] + arguments,
            directory: directory.path, environment: ["PATH": "/usr/bin:/bin"]
        )
        let result = try await LauncherHelperTestSupport.run(request, inheriting: request.environment)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(
            result.output.split(separator: 0).prefix(arguments.count).map { String(decoding: $0, as: UTF8.self) },
            arguments
        )
        let cwd = LauncherLaunchRequest(
            executable: "/bin/pwd",
            arguments: [],
            directory: directory.path,
            environment: [:]
        )
        let cwdResult = try await LauncherHelperTestSupport.run(cwd, inheriting: [:])
        XCTAssertEqual(cwdResult.status, 0)
        let reportedDirectory = try XCTUnwrap(String(decoding: cwdResult.output, as: UTF8.self)
            .split(separator: "\n").first)
        var actualDirectory = stat()
        var expectedDirectory = stat()
        XCTAssertEqual(stat(String(reportedDirectory), &actualDirectory), 0)
        XCTAssertEqual(stat(directory.path, &expectedDirectory), 0)
        XCTAssertEqual(actualDirectory.st_dev, expectedDirectory.st_dev)
        XCTAssertEqual(actualDirectory.st_ino, expectedDirectory.st_ino)
        let failure = LauncherLaunchRequest(
            executable: "/bin/sh", arguments: ["-c", "exit 9"], directory: directory.path, environment: [:]
        )
        let failureResult = try await LauncherHelperTestSupport.run(failure, inheriting: [:])
        XCTAssertEqual(failureResult.status, 9)
    }

    func testReusedTerminalReceivesCapturedEnvironmentWithoutPersistingIt() async throws {
        let value = "quotes ' \" $HOME; 雪\n" + String(repeating: "v", count: 80_000)
        let request = LauncherLaunchRequest(
            executable: "/bin/sh", arguments: ["-c", "printf '%s\\n%s' \"$OMNIWM_TRANSFER_TEST\" \"$TERM\"; exit 7"],
            directory: "/private/tmp", environment: [
                "PATH": "/usr/bin:/bin",
                "OMNIWM_TRANSFER_TEST": value,
                "TERM": "dumb"
            ]
        )
        let transfer = try LauncherHelperTestSupport.transfer(request: request)
        defer { transfer.cancel() }
        XCTAssertFalse(transfer.command.contains(value))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: transfer.helper.executable.path),
            try LauncherHelperTestSupport.executable.path
        )
        let entries = try FileManager.default.contentsOfDirectory(atPath: transfer.helper.folder.path)
        XCTAssertEqual(Set(entries), Set([
            transfer.helper.executable.lastPathComponent,
            URL(fileURLWithPath: transfer.endpoint).lastPathComponent
        ]))
        async let delivered: Void = transfer.waitForDelivery()
        let result = try await LauncherProcess.run(
            executable: transfer.arguments[0], arguments: Array(transfer.arguments.dropFirst()), environment: [
                "OMNIWM_TRANSFER_TEST": "stale",
                "TERM": "xterm-256color"
            ],
            deadline: failureBound, outputLimit: value.utf8.count + Int(getpagesize())
        )
        try await delivered
        XCTAssertEqual(result.status, 7)
        XCTAssertTrue(String(decoding: result.output, as: UTF8.self).hasPrefix(value + "\nxterm-256color"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transfer.endpoint))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transfer.helper.folder.path))
    }

    #if OMNIWM_LIVE_CHECKS
        func testRealNushellFishZshAndBothBashVersions() async throws {
            let environmentCache = LauncherEnvironmentCache(helperExecutable: try LauncherHelperTestSupport.executable)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let shells: [(LauncherShell, String, String)] = [
                (
                    .nushell,
                    root.appendingPathComponent(".cache/flake-tools/bin/nu").path,
                    "let omniwm_value = 'nushell'; /usr/bin/printf '%s' $omniwm_value"
                ),
                (
                    .fish,
                    root.appendingPathComponent(".cache/flake-tools/bin/fish").path,
                    "set omniwm_value fish; /usr/bin/printf '%s' $omniwm_value"
                ),
                (.zsh, "/bin/zsh", "omniwm_value=zsh; /usr/bin/printf '%s' \"$omniwm_value\""),
                (.bash, "/bin/bash", "omniwm_value=bash; /usr/bin/printf '%s' \"$omniwm_value\""),
                (.bash, "/opt/homebrew/bin/bash", "omniwm_value=bash; /usr/bin/printf '%s' \"$omniwm_value\"")
            ]
            for (shell, executable, command) in shells {
                XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable), executable)
                var configuration = LauncherConfiguration()
                configuration.shell = shell
                configuration.shellExecutable = executable
                configuration.terminal = .background
                let environment = try await LauncherEnvironmentCache.shared.environment(
                    for: configuration,
                    refresh: true
                )
                XCTAssertFalse(environment.values["PATH", default: ""].isEmpty)
                let catalog = await LauncherExecutableCatalog.scan(environment: environment.values)
                XCTAssertTrue(catalog.contains { $0.name == "printf" }, executable)
                XCTAssertTrue(catalog.contains { $0.name == "nix" }, executable)
                XCTAssertTrue(catalog.contains { $0.name == "brew" }, executable)
                var entry = LauncherEntry()
                entry.name = shell.rawValue
                entry.command = command
                let request = try await LauncherLaunchRequest.prepare(
                    entry: entry, configuration: configuration, environmentCache: environmentCache
                )
                let result = try await LauncherProcess.run(
                    executable: request.executable, arguments: request.arguments,
                    environment: request.environment, directory: request.directory
                )
                XCTAssertEqual(result.status, 0, executable)
                XCTAssertEqual(String(decoding: result.output, as: UTF8.self), shell.rawValue, executable)
            }
        }
    #endif
}
