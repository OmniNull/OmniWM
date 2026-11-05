// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class AssetCatalogProcessRunnerTests: XCTestCase {
    private let timeout = Duration.seconds(1)

    private func run(
        _ executableURL: URL,
        arguments: [String],
        sleeper: ManualSleeper = ManualSleeper()
    ) async -> Data? {
        await WorkspaceBarAssetCatalogProcessRunner.run(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout,
            sleep: { try await sleeper.sleep(for: $0) }
        )
    }

    func testSuccessfulCommandReturnsStandardOutput() async {
        let data = await run(URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["asset-catalog"])

        XCTAssertEqual(data, Data("asset-catalog".utf8))
    }

    func testMissingExecutableReturnsNil() async {
        let data = await run(
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "OmniWMMissingExecutable-\(UUID().uuidString)"
            ),
            arguments: []
        )

        XCTAssertNil(data)
    }

    func testNonzeroExitReturnsNil() async {
        let data = await run(URL(fileURLWithPath: "/usr/bin/false"), arguments: [])

        XCTAssertNil(data)
    }

    func testTimeoutTerminatesCommand() async throws {
        let startedURL = try makeStartedFile(named: "OmniWMAssetCatalogTimeout")
        defer {
            try? FileManager.default.removeItem(at: startedURL)
        }

        let sleeper = ManualSleeper()
        let task = Task {
            await run(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: sleepingCommandArguments(startedURL: startedURL),
                sleeper: sleeper
            )
        }
        defer { task.cancel() }
        let processIdentifier = try await startedProcessIdentifier(at: startedURL)
        var processExited = false
        defer {
            if !processExited {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }

        await sleeper.waitForPendingSleeps(1)
        XCTAssertEqual(sleeper.requestedDurations, [timeout])
        sleeper.resumeNext()
        let data = await task.value

        XCTAssertNil(data)
        try await waitForExit(of: processIdentifier)
        processExited = true
    }

    func testCancellationTerminatesCommand() async throws {
        let startedURL = try makeStartedFile(named: "OmniWMAssetCatalogCancellation")
        defer {
            try? FileManager.default.removeItem(at: startedURL)
        }

        let task = Task {
            await run(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: sleepingCommandArguments(startedURL: startedURL)
            )
        }
        defer { task.cancel() }

        let processIdentifier = try await startedProcessIdentifier(at: startedURL)
        var processExited = false
        defer {
            if !processExited {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }
        task.cancel()
        let data = await task.value

        XCTAssertNil(data)
        try await waitForExit(of: processIdentifier)
        processExited = true
    }

    private func sleepingCommandArguments(startedURL: URL) -> [String] {
        [
            "-c",
            "echo $$ > \"$1\"; exec /bin/sleep 30",
            "sh",
            startedURL.path
        ]
    }

    private func makeStartedFile(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try Data().write(to: url)
        return url
    }

    private func startedProcessIdentifier(at url: URL) async throws -> pid_t {
        let descriptor = open(url.path, O_EVTONLY)
        let (writes, written) = boundedChanges()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend],
            queue: .main
        )
        source.setEventHandler { written.yield() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        defer { source.cancel() }
        var started: pid_t?
        await writes.wait {
            let text = try? String(contentsOf: url, encoding: .utf8)
            started = text.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return started != nil
        }
        return try XCTUnwrap(started, "Command did not start")
    }

    private func waitForExit(of processIdentifier: pid_t) async throws {
        let (exits, exited) = boundedChanges()
        let source = DispatchSource.makeProcessSource(identifier: processIdentifier, eventMask: .exit, queue: .main)
        source.setEventHandler { exited.yield() }
        source.resume()
        defer { source.cancel() }
        var exit = exits.makeAsyncIterator()
        try await exit.change()
    }
}
