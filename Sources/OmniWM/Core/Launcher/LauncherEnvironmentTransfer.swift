// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
import Synchronization

final class LauncherEnvironmentTransfer: Sendable {
    private struct State {
        var result: Result<Void, LauncherFailure>?
        var continuation: CheckedContinuation<Void, Error>?
        var channel: DispatchIO?
    }

    let endpoint: String
    let marker = UUID().uuidString
    private let folder: URL
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "com.omniwm.launcher.environment", qos: .userInitiated)
    private let reader: DispatchSourceRead
    private let timer: DispatchSourceTimer
    private let payload: Data
    private let state = Mutex(State())

    init(request: LauncherLaunchRequest) throws {
        folder = URL(fileURLWithPath: "/private/tmp/omniwm-env-" + UUID().uuidString, isDirectory: true)
        endpoint = folder.appendingPathComponent("environment.sock").path
        payload = Data((request.terminalShellCommand + "\n" + marker).utf8)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        let listener = descriptor
        guard descriptor >= 0
        else {
            throw LauncherFailure(String(localized: "The launcher environment connection could not be created."))
        }
        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = Array(endpoint.utf8CString)
            guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw LauncherFailure(String(localized: "The launcher environment connection path is too long."))
            }
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                for (index, byte) in path.enumerated() { bytes[index] = UInt8(bitPattern: byte) }
            }
            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            address.sun_len = UInt8(size)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, size) }
            }
            guard bound == 0, listen(descriptor, 1) == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
                throw LauncherFailure(String(localized: "The launcher environment connection could not be opened."))
            }
        } catch {
            close(descriptor)
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        timer = DispatchSource.makeTimerSource(queue: queue)
        reader.setEventHandler { self.acceptConnection() }
        reader.setCancelHandler { [descriptor] in close(descriptor) }
        timer.setEventHandler {
            self
                .finish(
                    .failure(
                        LauncherFailure(
                            String(localized: "The terminal did not receive the launcher environment in time.")
                        )
                    )
                )
        }
        timer.schedule(deadline: .now() + 15)
        reader.resume()
        timer.resume()
    }

    func waitForDelivery() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Void, LauncherFailure>? = state.withLock { state in
                if let result = state.result { return result }
                state.continuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result.mapError { $0 as Error }) }
        }
    }

    func cancel() {
        queue.async {
            self.finish(.failure(LauncherFailure(String(localized: "The terminal launch was canceled."))))
        }
    }

    private func acceptConnection() {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else {
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                finish(
                    .failure(
                        LauncherFailure(
                            String(localized: "The terminal could not connect to its launcher environment.")
                        )
                    )
                )
            }
            return
        }
        reader.setEventHandler(handler: nil)
        reader.cancel()
        var enabled: Int32 = 1
        guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(client)
            finish(
                .failure(
                    LauncherFailure(String(localized: "The terminal environment connection could not be configured."))
                )
            )
            return
        }
        let channel = DispatchIO(type: .stream, fileDescriptor: client, queue: queue) { _ in close(client) }
        state.withLock { $0.channel = channel }
        let data = payload.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: data, queue: queue) { done, _, error in
            if error != 0 {
                self
                    .finish(
                        .failure(
                            LauncherFailure(String(localized: "The terminal could not read its launcher environment."))
                        )
                    )
            } else if done {
                self.finish(.success(()))
            }
        }
    }

    private func finish(_ result: Result<Void, LauncherFailure>) {
        let completion = state.withLock { state -> (CheckedContinuation<Void, Error>?, DispatchIO?)? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.continuation = nil
                state.channel = nil
            }
            return (state.continuation, state.channel)
        }
        guard let (continuation, channel) = completion else { return }
        reader.setEventHandler(handler: nil)
        reader.cancel()
        timer.setEventHandler(handler: nil)
        timer.cancel()
        if case .success = result { channel?.close() }
        else { channel?.close(flags: .stop) }
        try? FileManager.default.removeItem(at: folder)
        continuation?.resume(with: result.mapError { $0 as Error })
    }
}
