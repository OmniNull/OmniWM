// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC
import XCTest

final class IPCWindowOpaqueIDTests: XCTestCase {
    func testRoundTripsOpaqueSessionTokens() {
        let cases: [(String, Int32, Int)] = [
            (UUID().uuidString, 12_345, 67),
            ("prefix:suffix", 42, 7),
            ("a:b:c:d", 3, 999_999),
            ("???>>>", .min, .max),
            ("prefix\u{0600}", 42, 7)
        ]
        for (token, pid, windowId) in cases {
            let opaque = IPCWindowOpaqueID.encode(pid: pid, windowId: windowId, sessionToken: token)
            XCTAssertEqual(opaque, opaqueID(payload: "\(token):\(pid):\(windowId)"))
            XCTAssertEqual(
                IPCWindowOpaqueID.validate(opaque, expectingSessionToken: token),
                .valid(pid: pid, windowId: windowId),
                token
            )
        }
    }

    func testStreamingIDsAppendExactlyTheCanonicalBytesAcrossBitBoundaries() {
        let sessions = ["", "x", "xy", "???>>>", "🌿", "前:後", UUID().uuidString]
        let processes: [Int32] = [.min, -1, 0, 1, .max]
        let windows: [Int] = [.min, -1, 0, 1, .max]
        for session in sessions {
            let encoder = IPCWindowOpaqueID.Encoder(sessionToken: session)
            for process in processes {
                var bytes = Data("prefix".utf8)
                var expected = "prefix"
                for window in windows {
                    encoder.append(pid: process, windowId: window, to: &bytes)
                    expected += opaqueID(payload: "\(session):\(process):\(window)")
                    XCTAssertEqual(bytes, Data(expected.utf8))
                }
            }
        }
    }

    func testMismatchedSessionTokenReportsStale() {
        let opaque = IPCWindowOpaqueID.encode(pid: 5, windowId: 1, sessionToken: "session-a")

        XCTAssertEqual(
            IPCWindowOpaqueID.validate(opaque, expectingSessionToken: "session-b"),
            .stale
        )
    }

    func testMalformedOpaqueIDReportsInvalid() {
        for malformed in ["", "ow_", "not-a-prefix", "ow_not-base64$$"] {
            XCTAssertEqual(
                IPCWindowOpaqueID.validate(malformed, expectingSessionToken: "session"),
                .invalid
            )
        }
    }

    func testMalformedDecodedPayloadReportsInvalid() {
        for payload in [
            "session:42",
            "session:not-a-pid:7",
            "session:42:not-a-window",
            "session::7",
            "session:42:"
        ] {
            XCTAssertEqual(
                IPCWindowOpaqueID.validate(opaqueID(payload: payload), expectingSessionToken: "session"),
                .invalid
            )
        }
    }

    func testDecodeReturnsNilForStaleOrInvalid() {
        let token = "session"
        let valid = IPCWindowOpaqueID.encode(pid: 1, windowId: 2, sessionToken: token)

        XCTAssertNotNil(IPCWindowOpaqueID.decode(valid, expectingSessionToken: token))
        XCTAssertNil(IPCWindowOpaqueID.decode(valid, expectingSessionToken: "other"))
        XCTAssertNil(IPCWindowOpaqueID.decode("ow_bogus", expectingSessionToken: token))
    }

    private func opaqueID(payload: String) -> String {
        "ow_" + Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
