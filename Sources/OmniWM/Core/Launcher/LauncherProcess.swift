// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
import Synchronization

struct LauncherProcessResult: Sendable {
    let status: Int32
    let output: Data
    let truncated: Bool
}

final class LauncherExpiry: Sendable {
    private let state = Mutex<(fired: Bool, expire: (@Sendable () -> Void)?)>((false, nil))

    func fire() {
        let expire = state.withLock { state in
            state.fired = true
            return state.expire.take()
        }
        expire?()
    }

    fileprivate func register(_ expire: @escaping @Sendable () -> Void) {
        let fired = state.withLock { state in
            if !state.fired { state.expire = expire }
            return state.fired
        }
        if fired { expire() }
    }
}

enum LauncherProcess {
    @concurrent
    static func start(_ argv: [String], environment: [String: String]? = nil) async throws {
        let environment = environment ?? ProcessInfo.processInfo.environment
        let directory = FileManager.default.currentDirectoryPath
        guard let program = argv.first, !program.isEmpty else { throw LauncherFailure("Missing executable.") }
        let executable: String
        if program.hasPrefix("/") {
            executable = program
        } else {
            guard !program.contains("/"), let path = environment["PATH"] else {
                throw LauncherFailure("No executable for '\(program)' on OmniWM's PATH.")
            }
            let workingDirectory = URL(fileURLWithPath: directory, isDirectory: true)
            let folders = path.components(separatedBy: ":")
            guard let match = folders.lazy.map({ folder in
                let base = folder.isEmpty ? workingDirectory : URL(
                    fileURLWithPath: folder,
                    relativeTo: workingDirectory
                )
                return base.appendingPathComponent(program).standardizedFileURL.path
            }).first(where: { candidate in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory)
                    && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: candidate)
            }) else { throw LauncherFailure("No executable for '\(program)' on OmniWM's PATH.") }
            executable = match
        }
        let request = LauncherLaunchRequest(
            executable: executable, arguments: Array(argv.dropFirst()), directory: directory, environment: environment
        )
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, Error>) in
            do {
                let operation = try Operation(request: request, outputLimit: 0, continuation: nil)
                operation.start(deadline: nil, captureStandardError: true, started: started)
            } catch {
                started.resume(throwing: error)
            }
        }
    }

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: String? = nil,
        deadline: TimeInterval? = nil,
        expiry: LauncherExpiry? = nil,
        outputLimit: Int = 65_536,
        captureStandardError: Bool = true
    ) async throws -> LauncherProcessResult {
        let request = LauncherLaunchRequest(
            executable: executable, arguments: arguments,
            directory: directory ?? FileManager.default.currentDirectoryPath, environment: environment
        )
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let operation = try Operation(request: request, outputLimit: outputLimit, continuation: continuation)
                operation.start(deadline: deadline, expiry: expiry, captureStandardError: captureStandardError)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private struct State {
        var output = Data()
        var truncated = false
        var reachedEOF = false
        var finished = false
        var failure: LauncherFailure?
    }

    private final class Operation: Sendable {
        private let state = Mutex(State())
        private let process = Process()
        private let pipe: Pipe
        private let queue: DispatchQueue
        private let reader: DispatchSourceRead
        private let timer: DispatchSourceTimer
        private let descriptor: Int32
        private let outputLimit: Int
        private let continuation: CheckedContinuation<LauncherProcessResult, Error>?

        init(
            request: LauncherLaunchRequest, outputLimit: Int,
            continuation: CheckedContinuation<LauncherProcessResult, Error>?
        ) throws {
            let pipe = Pipe()
            let queue = DispatchQueue(label: "com.omniwm.launcher.process", qos: .userInitiated)
            descriptor = pipe.fileHandleForReading.fileDescriptor
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
                throw LauncherFailure(String(localized: "The command output pipe could not be configured."))
            }
            self.pipe = pipe
            self.queue = queue
            self.outputLimit = outputLimit
            self.continuation = continuation
            reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            timer = DispatchSource.makeTimerSource(queue: queue)
            process.executableURL = URL(fileURLWithPath: request.executable)
            process.arguments = request.arguments
            process.environment = request.environment
            process.currentDirectoryURL = URL(fileURLWithPath: request.directory)
        }

        func start(
            deadline: TimeInterval?, expiry: LauncherExpiry? = nil, captureStandardError: Bool,
            started: CheckedContinuation<Void, Error>? = nil
        ) {
            queue.async { [self] in
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = pipe
                process.standardError = captureStandardError ? pipe : FileHandle.nullDevice
                reader.setEventHandler { self.drain() }
                reader.setCancelHandler { [pipe] in try? pipe.fileHandleForReading.close() }
                process.terminationHandler = { process in
                    self.queue.async { self.finish(status: process.terminationStatus) }
                }
                timer.setEventHandler { self.expire() }
                if let deadline { timer.schedule(deadline: .now() + deadline) }
                reader.resume()
                timer.resume()
                do {
                    try process.run()
                } catch {
                    try? pipe.fileHandleForWriting.close()
                    finish(failure: LauncherFailure(error.localizedDescription))
                    started?.resume(throwing: error)
                    return
                }
                started?.resume()
                expiry?.register { [weak self] in
                    guard let self else { return }
                    queue.async { self.expire() }
                }
                do {
                    try pipe.fileHandleForWriting.close()
                } catch {
                    finish(failure: LauncherFailure(error.localizedDescription))
                }
            }
        }

        private func drain() {
            guard !state.withLock({ $0.reachedEOF || $0.finished }) else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            for _ in 0 ..< 32 {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard continuation != nil else { continue }
                    state.withLock { state in
                        let remaining = max(0, outputLimit - state.output.count)
                        state.output.append(contentsOf: buffer.prefix(min(remaining, count)))
                        if count > remaining { state.truncated = true }
                    }
                } else if count == 0 {
                    state.withLock { $0.reachedEOF = true }
                    reader.cancel()
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                } else {
                    state
                        .withLock {
                            $0.failure = LauncherFailure(String(localized: "The command output could not be read."))
                        }
                    return
                }
            }
        }

        private func expire() {
            guard process.isRunning else { return }
            state
                .withLock {
                    $0
                        .failure =
                        LauncherFailure(String(localized: "The shell did not finish loading its environment in time."))
                }
            if kill(process.processIdentifier, SIGKILL) == -1, errno != ESRCH {
                state
                    .withLock {
                        $0.failure = LauncherFailure(String(localized: "The timed-out shell could not be stopped."))
                    }
            }
        }

        private func finish(status: Int32? = nil, failure: LauncherFailure? = nil) {
            drain()
            let result: Result<LauncherProcessResult, LauncherFailure>? = state.withLock { state in
                guard !state.finished else { return nil }
                state.finished = true
                if let failure = failure ?? state.failure { return .failure(failure) }
                return .success(LauncherProcessResult(
                    status: status ?? -1,
                    output: state.output,
                    truncated: state.truncated
                ))
            }
            guard let result else { return }
            timer.cancel()
            timer.setEventHandler(handler: nil)
            reader.setEventHandler(handler: nil)
            reader.cancel()
            process.terminationHandler = nil
            continuation?.resume(with: result.mapError { $0 as Error })
        }
    }
}

struct LauncherEnvironment: Sendable {
    let shell: LauncherShell
    let executable: String
    let values: [String: String]

    static func load(configuration: LauncherConfiguration, helperExecutable: URL? = nil) async throws -> Self {
        let inherited = ProcessInfo.processInfo.environment
        let resolved = try LauncherPaths.shell(
            configuration.shell, executable: configuration.shellExecutable, environment: inherited
        )
        let marker = "OMNIWM_ENV_" + UUID().uuidString
        let helper = try LauncherHelperExecutable(executable: helperExecutable)
        defer { helper.remove() }
        let command = helper.executable.path + " __environment " + marker
        let result = try await LauncherProcess.run(
            executable: resolved.path,
            arguments: resolved.kind.commandArguments(command, interactive: true),
            environment: inherited,
            directory: FileManager.default.homeDirectoryForCurrentUser.path,
            deadline: 10,
            outputLimit: 1_048_576,
            captureStandardError: false
        )
        let prefix = Data((marker + "\0").utf8)
        guard result.status == 0, !result.truncated, let range = result.output.range(of: prefix) else {
            throw LauncherFailure(String(localized: "The selected shell could not provide its environment."))
        }
        var values: [String: String] = [:]
        for item in result.output[range.upperBound...].split(separator: 0) {
            guard let separator = item.firstIndex(of: 61) else { continue }
            let key = String(decoding: item[..<separator], as: UTF8.self)
            values[key] = String(decoding: item[item.index(after: separator)...], as: UTF8.self)
        }
        guard let path = values["PATH"], !path.isEmpty else {
            throw LauncherFailure(String(localized: "The selected shell did not provide PATH."))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var seen: Set<String> = []
        let folders = path.split(separator: ":").map(String.init)
            + LauncherPaths.binFolders(home: home, environment: values) + configuration.cliFolders
            .map(LauncherPaths.expanded)
        values["PATH"] = folders.filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
        values["SHELL"] = resolved.path
        return Self(shell: resolved.kind, executable: resolved.path, values: values)
    }
}
