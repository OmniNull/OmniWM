// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation

enum AppThemeSocketReply: Equatable, Sendable {
    case notRunning
    case line(String)
    case failed(String)
}

enum AppThemeHerdrSocket {
    static let requestID = "omniwm:app-theming"
    static let replyTimeout: TimeInterval = 5
    static let maximumReply = 1 << 20
    static let maximumSessionName = 64
    private static let readChunk = 4096
    private static let defaultSession = "default"

    static func path(variables: [String: String], home: URL) -> String {
        if let path = variables["HERDR_SOCKET_PATH"], !path.isEmpty { return path }
        var folder = AppThemeOutputPolicy.configHome(environment: variables, home: home)
            .appendingPathComponent("herdr", isDirectory: true)
        if let session = variables["HERDR_SESSION"], session != defaultSession, isValidSession(session) {
            folder = folder.appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(session, isDirectory: true)
        }
        return folder.appendingPathComponent("herdr.sock").path
    }

    static func isValidSession(_ name: String) -> Bool {
        let allowed = [
            UInt8(ascii: "a") ... UInt8(ascii: "z"),
            UInt8(ascii: "A") ... UInt8(ascii: "Z"),
            UInt8(ascii: "0") ... UInt8(ascii: "9")
        ]
        return !name.isEmpty && name.utf8.count <= maximumSessionName && name != "." && name != ".."
            && name.utf8.allSatisfy { byte in
                allowed.contains { $0.contains(byte) } || "._-".utf8.contains(byte)
            }
    }

    typealias Clock = () -> UInt64

    static func uptime() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    private struct Deadline {
        let end: UInt64
        let clock: Clock

        var remaining: timeval? {
            let now = clock()
            guard now < end else { return nil }
            let left = end - now
            let microseconds = max(left / nanosecondsPerMicrosecond, 1)
            return timeval(
                tv_sec: Int(microseconds / microsecondsPerSecond),
                tv_usec: Int32(microseconds % microsecondsPerSecond)
            )
        }

        var passed: Bool {
            clock() >= end
        }

        func bound(_ descriptor: Int32, _ option: Int32) -> Bool {
            guard var wait = remaining else { return false }
            setsockopt(descriptor, SOL_SOCKET, option, &wait, socklen_t(MemoryLayout<timeval>.size))
            return true
        }
    }

    private static let nanosecondsPerMicrosecond: UInt64 = 1000
    private static let microsecondsPerSecond: UInt64 = 1_000_000
    private static let nanosecondsPerSecond: TimeInterval = 1_000_000_000

    static func send(
        _ method: String,
        to path: String,
        timeout: TimeInterval = replyTimeout,
        clock: @escaping Clock = uptime
    ) -> AppThemeSocketReply {
        let deadline = Deadline(end: clock() + UInt64(timeout * nanosecondsPerSecond), clock: clock)
        let timedOut = AppThemeSocketReply.failed(String(localized: "timed out"))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return .failed(String(localized: "its socket path is too long"))
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = UInt8(bitPattern: byte) }
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .failed(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard deadline.bound(descriptor, SO_SNDTIMEO) else { return timedOut }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, size) }
        }
        guard connected == 0 else {
            let error = errno
            return error == ENOENT || error == ECONNREFUSED ? .notRunning : .failed(String(cString: strerror(error)))
        }
        guard let request = try? JSONSerialization.data(
            withJSONObject: ["id": requestID, "method": method, "params": [String: String]()],
            options: [.sortedKeys]
        ) else {
            return .failed(String(localized: "the request couldn’t be written"))
        }
        guard deadline.bound(descriptor, SO_SNDTIMEO) else { return timedOut }
        if let problem = write(request + Data("\n".utf8), to: descriptor) { return .failed(problem) }
        return readLine(from: descriptor, before: deadline, timedOut: timedOut)
    }

    private static func write(_ data: Data, to descriptor: Int32) -> String? {
        data.withUnsafeBytes { buffer -> String? in
            var offset = 0
            while offset < buffer.count {
                let sent = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if sent < 0 {
                    if errno == EINTR { continue }
                    return errno == EAGAIN ? String(localized: "timed out") : String(cString: strerror(errno))
                }
                offset += sent
            }
            return nil
        }
    }

    private static func readLine(
        from descriptor: Int32,
        before deadline: Deadline,
        timedOut: AppThemeSocketReply
    ) -> AppThemeSocketReply {
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: readChunk)
        while reply.count <= maximumReply {
            guard deadline.bound(descriptor, SO_RCVTIMEO) else { return timedOut }
            let count = recv(descriptor, &chunk, chunk.count, 0)
            if count < 0 {
                if errno == EINTR { continue }
                return errno == EAGAIN ? timedOut : .failed(String(cString: strerror(errno)))
            }
            guard count > 0 else { return .failed(String(localized: "it closed the connection without a reply")) }
            reply.append(contentsOf: chunk[0 ..< count])
            guard !deadline.passed else { return timedOut }
            if let end = reply.firstIndex(of: UInt8(ascii: "\n")) {
                return .line(String(decoding: reply[reply.startIndex ..< end], as: UTF8.self))
            }
        }
        return .failed(String(localized: "its reply was too long"))
    }
}
