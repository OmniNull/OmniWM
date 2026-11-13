// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
@testable import OmniWM
import os
import XCTest

final class AppThemeHerdrSocketTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        var template = Array("/tmp/omniwm-herdr.XXXXXX".utf8CString)
        let made = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress).map { String(cString: $0) }
        }
        folder = try URL(fileURLWithPath: XCTUnwrap(made))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func listen(at path: String) throws -> Int32 {
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = UInt8(bitPattern: byte) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, size) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(listener, 1), 0)
        return listener
    }

    private static func acceptClient(_ listener: Int32) -> Int32 {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return client }
        var enabled: Int32 = 1
        XCTAssertEqual(setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)), 0)
        return client
    }

    private func serveOnce(
        _ listener: Int32,
        reply: String,
        into received: OSAllocatedUnfairLock<String>
    ) -> DispatchGroup {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            let client = Self.acceptClient(listener)
            guard client >= 0 else { return }
            defer { close(client) }
            var data = Data()
            var byte: UInt8 = 0
            while Darwin.read(client, &byte, 1) == 1, byte != UInt8(ascii: "\n") {
                data.append(byte)
            }
            let line = String(decoding: data, as: UTF8.self)
            received.withLock { $0 = line }
            _ = reply.withCString { Darwin.write(client, $0, strlen($0)) }
        }
        return group
    }

    private final class ScriptedClock: Sendable {
        private let reading = OSAllocatedUnfairLock<UInt64>(initialState: 0)

        func now() -> UInt64 {
            reading.withLock { $0 }
        }

        func set(_ value: UInt64) {
            reading.withLock { $0 = value }
        }
    }

    private var timeoutNanoseconds: UInt64 {
        UInt64(AppThemeHerdrSocket.replyTimeout * Double(NSEC_PER_SEC))
    }

    private func serve(_ listener: Int32, _ script: @escaping @Sendable (Int32) -> Void) -> DispatchGroup {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            let client = Self.acceptClient(listener)
            guard client >= 0 else { return }
            defer { close(client) }
            var byte: UInt8 = 0
            while Darwin.read(client, &byte, 1) == 1, byte != UInt8(ascii: "\n") {}
            script(client)
        }
        return group
    }

    private static func send(_ client: Int32, _ text: String) {
        _ = text.withCString { Darwin.write(client, $0, strlen($0)) }
    }

    func testAReplyThatIsStillArrivingAtTheDeadlineIsTimedOut() throws {
        let path = folder.appendingPathComponent("herdr.sock").path
        let listener = try listen(at: path)
        defer { close(listener) }
        let clock = ScriptedClock()
        let late = timeoutNanoseconds + 1
        let served = serve(listener) { client in
            Self.send(client, #"{"id":"\#(AppThemeHerdrSocket.requestID)","#)
            clock.set(late)
            Self.send(client, #""result":{"type":"config_reload","status":"applied","diagnostics":[]}}"# + "\n")
        }
        let reply = AppThemeHerdrSocket.send("server.reload_config", to: path, clock: clock.now)
        XCTAssertEqual(served.wait(timeout: .now() + failureBound), .success)
        XCTAssertEqual(reply, .failed(String(localized: "timed out")))
    }

    func testAServerThatNeverRepliesIsTimedOutAtTheDeadline() throws {
        let path = folder.appendingPathComponent("herdr.sock").path
        let listener = try listen(at: path)
        defer { close(listener) }
        let clock = ScriptedClock()
        let served = serve(listener) { client in
            var byte: UInt8 = 0
            _ = Darwin.read(client, &byte, 1)
        }
        let nearlyDue = timeoutNanoseconds - NSEC_PER_USEC
        let reply = AppThemeHerdrSocket.send("server.reload_config", to: path) {
            defer { clock.set(nearlyDue) }
            return clock.now()
        }
        XCTAssertEqual(served.wait(timeout: .now() + failureBound), .success)
        XCTAssertEqual(reply, .failed(String(localized: "timed out")))
    }

    func testAReloadRequestIsOneJSONLineAndTheReplyLineComesBack() throws {
        let path = folder.appendingPathComponent("herdr.sock").path
        let listener = try listen(at: path)
        defer { close(listener) }
        let received = OSAllocatedUnfairLock(initialState: "")
        let answer = #"{"id":"\#(AppThemeHerdrSocket.requestID)","result":{"type":"config_reload","status":"applied","diagnostics":[]}}"#
        let served = serveOnce(listener, reply: answer + "\n", into: received)
        let reply = AppThemeHerdrSocket.send("server.reload_config", to: path)
        XCTAssertEqual(served.wait(timeout: .now() + failureBound), .success)
        XCTAssertEqual(reply, .line(answer))
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: received.withLock { Data($0.utf8) }) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "server.reload_config")
        XCTAssertEqual(request["id"] as? String, AppThemeHerdrSocket.requestID)
        XCTAssertEqual((request["params"] as? [String: Any])?.isEmpty, true)
    }

    func testAMissingOrStaleSocketMeansHerdrIsNotRunning() throws {
        let missing = folder.appendingPathComponent("missing.sock").path
        XCTAssertEqual(AppThemeHerdrSocket.send("server.reload_config", to: missing), .notRunning)
        let stale = folder.appendingPathComponent("stale.sock").path
        close(try listen(at: stale))
        XCTAssertEqual(AppThemeHerdrSocket.send("server.reload_config", to: stale), .notRunning)
    }

    func testAServerThatClosesWithoutReplyingIsAFailure() throws {
        let path = folder.appendingPathComponent("herdr.sock").path
        let listener = try listen(at: path)
        defer { close(listener) }
        let served = serveOnce(listener, reply: "", into: OSAllocatedUnfairLock(initialState: ""))
        let reply = AppThemeHerdrSocket.send("server.reload_config", to: path)
        XCTAssertEqual(served.wait(timeout: .now() + failureBound), .success)
        guard case .failed = reply else { return XCTFail("\(reply)") }
    }

    func testASocketPathTooLongForAUnixSocketIsAFailure() {
        let path = "/tmp/" + String(repeating: "x", count: MemoryLayout.size(ofValue: sockaddr_un().sun_path))
        guard case .failed = AppThemeHerdrSocket.send("server.reload_config", to: path) else {
            return XCTFail("a path longer than sun_path was accepted")
        }
    }
}
