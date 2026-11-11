// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct AppThemeCommandResult: Equatable, Sendable {
    var status: Int32
    var output: String
    var timedOut = false

    var succeeded: Bool {
        status == 0 && !timedOut
    }
}

struct AppThemeEnvironment: Sendable {
    var run: @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> AppThemeCommandResult
    var isAppRunning: @Sendable (_ bundleIdentifier: String) -> Bool
    var executable: @Sendable (_ name: String) -> String?
    var userID: UInt32 = getuid()

    static let searchFolders = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.cargo/bin"]

    static let live = AppThemeEnvironment(
        run: { executable, arguments, timeout in
            AppThemeProcessRunner.run(executable, arguments, timeout: timeout)
        },
        isAppRunning: { bundleIdentifier in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
        },
        executable: { name in
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return searchFolders
                .map { ($0.hasPrefix("~/") ? home + $0.dropFirst() : $0) + "/" + name }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }
    )
}

enum AppThemeProcessRunner {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> AppThemeCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = AppThemeEnvironment.searchFolders.map { $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 }
        environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let collected = DispatchSemaphore(value: 0)
        let output = AppThemeOutputBuffer()
        do {
            try process.run()
        } catch {
            return AppThemeCommandResult(status: -1, output: error.localizedDescription)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            collected.signal()
        }
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        let data = collected.wait(timeout: .now() + 1) == .success ? output.data : Data()
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AppThemeCommandResult(status: process.terminationStatus, output: text, timedOut: timedOut)
    }
}

private final class AppThemeOutputBuffer: @unchecked Sendable {
    var data = Data()
}
