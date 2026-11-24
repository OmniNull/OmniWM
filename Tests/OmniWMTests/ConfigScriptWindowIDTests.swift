// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

final class ConfigScriptWindowIDTests: XCTestCase {
    private let session = ConfigScriptSession.random()

    func testWindowIDsSpellTheSessionProcessAndWindowCanonically() {
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let hex = String(session.id, radix: 16)
        let padded = String(repeating: "0", count: ConfigScriptWindowID.sessionDigits - hex.count) + hex
        XCTAssertEqual(
            ConfigScriptWindowID.string(token, session: session),
            padded + "." + String(token.pid) + "." + String(token.windowId)
        )
    }

    func testWindowIDsRoundTripEveryTokenBitPattern() {
        let pids: [pid_t] = [0, 1, getpid(), .max, .min, -1]
        let windows: [Int] = [0, 1, Int(getpid()), .max, .min, -1]
        for session in [session, ConfigScriptSession(id: .min), ConfigScriptSession(id: .max)] {
            for pid in pids {
                for window in windows {
                    let token = WindowToken(pid: pid, windowId: window)
                    let text = ConfigScriptWindowID.string(token, session: session)
                    XCTAssertLessThanOrEqual(text.utf8.count, ConfigScriptWindowID.maximumLength)
                    let decoded = ConfigScriptWindowID.decode(text)
                    XCTAssertEqual(decoded?.session, session, text)
                    XCTAssertEqual(decoded?.token, token, text)
                }
            }
        }
    }

    func testWindowIDsAcceptOnlyTheCanonicalSpelling() {
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let valid = ConfigScriptWindowID.string(token, session: session)
        let parts = valid.split(separator: ".").map(String.init)
        let pid = parts[1]
        let window = parts[2]
        let sessionText = parts[0]
        let rejected = [
            "", ".", "..", sessionText, sessionText + "." + pid, valid + ".", valid + ".1", "." + valid,
            ConfigScriptWindowID.string(token, session: ConfigScriptSession(id: .max)).uppercased(),
            "g" + sessionText.dropFirst() + "." + pid + "." + window,
            String(sessionText.dropFirst()) + "." + pid + "." + window,
            sessionText + "0." + pid + "." + window,
            sessionText + ".0" + pid + "." + window,
            sessionText + "." + pid + ".0" + window,
            sessionText + ".+" + pid + "." + window,
            sessionText + "." + pid + ".-" + window,
            sessionText + "." + pid + "." + window + " ",
            sessionText + "." + String(UInt64(UInt32.max) + 1) + "." + window,
            sessionText + "." + pid + "." + UInt.max.description + "0",
            sessionText + "." + pid + "." + String(UInt.max / 10) + String(UInt.max % 10 + 1),
            IPCWindowOpaqueID.encode(token: token, sessionToken: UUID().uuidString)
        ]
        for text in rejected {
            XCTAssertNil(ConfigScriptWindowID.decode(text), text)
        }
        XCTAssertNotNil(ConfigScriptWindowID.decode(sessionText + ".0.0"))
    }
}
