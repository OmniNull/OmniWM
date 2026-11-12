// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation
@testable import OmniWM
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

    private final class Received: @unchecked Sendable {
        var line = ""
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

    private func serveOnce(_ listener: Int32, reply: String, into received: Received) -> DispatchGroup {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var data = Data()
            var byte: UInt8 = 0
            while Darwin.read(client, &byte, 1) == 1, byte != UInt8(ascii: "\n") {
                data.append(byte)
            }
            received.line = String(decoding: data, as: UTF8.self)
            _ = reply.withCString { Darwin.write(client, $0, strlen($0)) }
        }
        return group
    }

    func testAReloadRequestIsOneJSONLineAndTheReplyLineComesBack() throws {
        let path = folder.appendingPathComponent("herdr.sock").path
        let listener = try listen(at: path)
        defer { close(listener) }
        let received = Received()
        let answer = #"{"id":"omniwm:app-theming","result":{"type":"config_reload","status":"applied","diagnostics":[]}}"#
        let served = serveOnce(listener, reply: answer + "\n", into: received)
        let reply = AppThemeHerdrSocket.send("server.reload_config", to: path)
        XCTAssertEqual(served.wait(timeout: .now() + failureBound), .success)
        XCTAssertEqual(reply, .line(answer))
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(received.line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "server.reload_config")
        XCTAssertEqual(request["id"] as? String, "omniwm:app-theming")
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
        let served = serveOnce(listener, reply: "", into: Received())
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
