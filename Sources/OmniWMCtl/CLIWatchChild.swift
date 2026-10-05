// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
import OmniWMIPC

final class CLIWatchProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var currentProcess: Process?

    func set(_ process: Process) {
        lock.lock()
        currentProcess = process
        lock.unlock()
    }

    func clear(_ process: Process) {
        lock.lock()
        if currentProcess === process {
            currentProcess = nil
        }
        lock.unlock()
    }

    func terminateCurrent() {
        lock.lock()
        let process = currentProcess
        lock.unlock()

        guard let process, process.isRunning else { return }
        process.terminate()
    }
}

enum CLIWatchChild {
    enum Failure: Error {
        case childLaunch(Error)
    }

    enum WatchTerminationReason: Sendable, Equatable {
        case exit
        case uncaughtSignal
        case unknown
    }

    struct WatchChildResult: Sendable, Equatable {
        let terminationReason: WatchTerminationReason
        let terminationStatus: Int32
    }

    static func run(
        event: IPCEventEnvelope,
        childArguments: [String],
        processState: CLIWatchProcessState
    ) async throws -> WatchChildResult {
        guard let executableName = childArguments.first else {
            throw POSIXError(.EINVAL)
        }

        let process = Process()
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.executableURL = URL(fileURLWithPath: try resolveExecutablePath(named: executableName))
        process.arguments = Array(childArguments.dropFirst())
        process.environment = childEnvironment(for: event)

        try process.run()
        processState.set(process)
        defer {
            processState.clear(process)
        }

        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: IPCWire.encodeEventLine(event))
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            if process.isRunning {
                process.terminate()
            }
            _ = await waitForTermination(of: process)
            process.terminationHandler = nil
            processState.clear(process)
            throw error
        }

        let result = await waitForTermination(of: process)
        process.terminationHandler = nil
        processState.clear(process)
        return result
    }

    private static func waitForTermination(of process: Process) async -> WatchChildResult {
        await withCheckedContinuation { continuation in
            final class ResumeState: @unchecked Sendable {
                private let lock = NSLock()
                private var didResume = false
                private let continuation: CheckedContinuation<WatchChildResult, Never>

                init(continuation: CheckedContinuation<WatchChildResult, Never>) {
                    self.continuation = continuation
                }

                func resumeIfNeeded(with result: WatchChildResult) {
                    lock.lock()
                    let shouldResume = !didResume
                    didResume = true
                    lock.unlock()

                    guard shouldResume else { return }
                    continuation.resume(returning: result)
                }
            }

            let state = ResumeState(continuation: continuation)

            process.terminationHandler = { terminatedProcess in
                state.resumeIfNeeded(
                    with: WatchChildResult(
                        terminationReason: terminationReason(for: terminatedProcess.terminationReason),
                        terminationStatus: terminatedProcess.terminationStatus
                    )
                )
            }

            if !process.isRunning {
                state.resumeIfNeeded(
                    with: WatchChildResult(
                        terminationReason: terminationReason(for: process.terminationReason),
                        terminationStatus: process.terminationStatus
                    )
                )
            }
        }
    }

    private static func terminationReason(for reason: Process.TerminationReason) -> WatchTerminationReason {
        switch reason {
        case .exit:
            return .exit
        case .uncaughtSignal:
            return .uncaughtSignal
        @unknown default:
            return .unknown
        }
    }

    private static func childEnvironment(for event: IPCEventEnvelope) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["OMNIWM_EVENT_CHANNEL"] = event.channel.rawValue
        environment["OMNIWM_EVENT_KIND"] = event.result.kind.rawValue
        environment["OMNIWM_EVENT_ID"] = event.id
        return environment
    }

    static func resolveExecutablePath(
        named executableName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        if executableName.contains("/") {
            return executableName
        }

        let pathValue = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in pathValue.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(executableName)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        throw POSIXError(.ENOENT)
    }

    static func reportFailure(result: WatchChildResult, command: [String]) {
        let commandText = command.joined(separator: " ")
        let message: String

        switch result.terminationReason {
        case .exit:
            message = "omniwmctl watch: child exited with status \(result.terminationStatus): \(commandText)\n"
        case .uncaughtSignal:
            message = "omniwmctl watch: child terminated by signal \(result.terminationStatus): \(commandText)\n"
        case .unknown:
            message = "omniwmctl watch: child terminated unexpectedly: \(commandText)\n"
        }

        FileHandle.standardError.write(Data(message.utf8))
    }
}
