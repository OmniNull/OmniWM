// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import os

struct AppThemeCommandResult: Equatable, Sendable {
    var status: Int32
    var output: String
    var timedOut = false

    var succeeded: Bool {
        status == 0 && !timedOut
    }
}

struct AppThemeGhosttyApp: Equatable, Sendable {
    static let bundleIdentifier = "com.mitchellh.ghostty"
    static let signalReloadVersion = [1, 2]
    private static let nanosecondsPerSecond: TimeInterval = 1_000_000_000

    let process: AppThemeProcess
    let version: String?

    var pid: pid_t {
        process.pid
    }

    var reloadsOnSignal: Bool {
        guard let version else { return false }
        let numbers = version.split(separator: "-", maxSplits: 1).first?
            .split(separator: ".").map { Int($0) } ?? []
        guard !numbers.isEmpty, !numbers.contains(nil) else { return false }
        return !numbers.compactMap(\.self).lexicographicallyPrecedes(Self.signalReloadVersion)
    }

    static func runningVersion(bundle: URL, started: Date) -> String? {
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let plist = contents.appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String,
              let version = info["CFBundleShortVersionString"] as? String
        else { return nil }
        let files = [plist, contents.appendingPathComponent("MacOS").appendingPathComponent(executable)]
        return files.allSatisfy { statusChanged($0).map { $0 <= started } ?? false } ? version : nil
    }

    private static func statusChanged(_ url: URL) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let changed = info.st_ctimespec
        return Date(timeIntervalSince1970: TimeInterval(changed.tv_sec) + TimeInterval(changed.tv_nsec) /
            nanosecondsPerSecond)
    }

    static func running() -> [AppThemeGhosttyApp] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
            .compactMap { app in
                guard let process = AppThemeProcesses.identity(of: app.processIdentifier) else { return nil }
                return AppThemeGhosttyApp(
                    process: process,
                    version: app.bundleURL.flatMap { runningVersion(bundle: $0, started: process.started) }
                )
            }
    }
}

struct AppThemeProcess: Equatable, Sendable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let realUserID: uid_t
    let name: String

    private static let microsecondsPerSecond: TimeInterval = 1_000_000

    var started: Date {
        Date(timeIntervalSince1970: TimeInterval(startSeconds) + TimeInterval(startMicroseconds) / Self
            .microsecondsPerSecond)
    }
}

enum AppThemeProcesses {
    private static let headroom = 64

    static func list(named name: String, realUserID: uid_t) -> [AppThemeProcess] {
        let stride = MemoryLayout<pid_t>.stride
        let needed = proc_listpids(UInt32(PROC_RUID_ONLY), realUserID, nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / stride + headroom)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_RUID_ONLY), realUserID, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / stride).compactMap { pid in
            guard pid > 0, let process = identity(of: pid), process.name == name,
                  process.realUserID == realUserID
            else { return nil }
            return process
        }
    }

    static func identity(of pid: pid_t) -> AppThemeProcess? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, let name = name(of: pid) else {
            return nil
        }
        return AppThemeProcess(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
            realUserID: info.pbi_ruid,
            name: name
        )
    }

    static func signal(_ process: AppThemeProcess, _ signal: Int32) -> Int32 {
        guard identity(of: process.pid) == process else { return ESRCH }
        return kill(process.pid, signal) == 0 ? 0 : errno
    }

    static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

struct AppThemeEnvironment: Sendable {
    var run: @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> AppThemeCommandResult
    var ghosttyApps: @Sendable () -> [AppThemeGhosttyApp]
    var processes: @Sendable (_ name: String) -> [AppThemeProcess]
    var signal: @Sendable (_ process: AppThemeProcess, _ signal: Int32) -> Int32
    var herdr: @Sendable (_ socket: String, _ method: String) -> AppThemeSocketReply
    var variables: [String: String]
    var executable: @Sendable (_ name: String) -> String?

    var home: URL {
        URL(fileURLWithPath: variables["HOME"] ?? NSHomeDirectory(), isDirectory: true)
    }

    static let searchFolders = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.cargo/bin"]

    static let live = AppThemeEnvironment(
        run: { executable, arguments, timeout in
            AppThemeProcessRunner.run(executable, arguments, timeout: timeout)
        },
        ghosttyApps: { AppThemeGhosttyApp.running() },
        processes: { AppThemeProcesses.list(named: $0, realUserID: getuid()) },
        signal: { process, signal in
            AppThemeProcesses.signal(process, signal)
        },
        herdr: { socket, method in
            AppThemeHerdrSocket.send(method, to: socket)
        },
        variables: ProcessInfo.processInfo.environment,
        executable: { name in
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return searchFolders
                .map { ($0.hasPrefix("~/") ? home + $0.dropFirst() : $0) + "/" + name }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }
    )
}

enum AppThemeProcessRunner {
    static let terminationGrace: TimeInterval = 1

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
        let output = OSAllocatedUnfairLock(initialState: Data())
        do {
            try process.run()
        } catch {
            return AppThemeCommandResult(status: -1, output: error.localizedDescription)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output.withLock { $0 = data }
            collected.signal()
        }
        let deadline = DispatchTime.now() + timeout
        var timedOut = false
        if finished.wait(timeout: deadline) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + terminationGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        let complete = collected.wait(timeout: max(deadline, .now())) == .success
        return result(
            status: process.terminationStatus,
            output: complete ? output.withLock { $0 } : nil,
            timedOut: timedOut
        )
    }

    static func result(status: Int32, output: Data?, timedOut: Bool) -> AppThemeCommandResult {
        guard let output else {
            return AppThemeCommandResult(
                status: status,
                output: String(localized: "its output didn’t finish"),
                timedOut: true
            )
        }
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return AppThemeCommandResult(status: status, output: text, timedOut: timedOut)
    }
}
