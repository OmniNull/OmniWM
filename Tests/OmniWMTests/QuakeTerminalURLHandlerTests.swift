// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import GhosttyKit
@testable import OmniWM
import XCTest

@MainActor
final class QuakeTerminalURLHandlerTests: XCTestCase {
    func testOpensWebAndEmailHyperlinks() {
        for string in [
            "https://github.com/OmniNull/OmniWM/issues?state=open#results",
            "http://localhost:3000/path",
            "HTTPS://example.com/path",
            "mailto:hello@example.com?subject=Hello%20there"
        ] {
            var opened: [URL] = []
            XCTAssertTrue(handle(string) {
                opened.append($0)
                return true
            })
            XCTAssertEqual(opened.map(\.absoluteString), [string])
        }
    }

    func testRejectsUnsafeOSC8TargetsWithoutFallback() {
        let targets = [
            "file:///tmp/payload.command", "file:///Applications/Terminal.app",
            "file:///tmp/document.txt", "javascript:alert(1)", "data:text/html,hello",
            "vscode://file/tmp/example", "/tmp/payload.command", "example.com",
            "", "https:", "https:relative", "https://", "mailto:", "https://example.com/%zz"
        ] + ["\0", "\n", "\r", "\t", " ", "\u{0085}", "\u{200B}", "\u{202E}", "\u{2028}", "\u{FEFF}"].map {
            "https://example.com/\($0)target"
        }
        for string in targets {
            XCTAssertTrue(handle(string) { _ in
                XCTFail("Opened \(string)")
                return true
            })
        }
    }

    func testDecodesOnlyExplicitLengthWithoutNullTerminator() throws {
        let target = "https://example.com/path"
        let bytes = Array((target + "ignored").utf8)
        var opened: URL?
        let handled = try bytes.withUnsafeBytes { buffer in
            try QuakeTerminalURLHandler.handle(ghostty_action_open_url_s(
                kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8,
                url: XCTUnwrap(buffer.baseAddress).assumingMemoryBound(to: CChar.self),
                len: UInt(target.utf8.count)
            )) {
                opened = $0
                return true
            }
        }
        XCTAssertTrue(handled)
        XCTAssertEqual(opened?.absoluteString, target)
    }

    func testRejectsInvalidUTF8WithoutOpeningOrFallingBack() throws {
        let bytes: [UInt8] = Array("https://example.com/".utf8) + [0xFF]
        let handled = try bytes.withUnsafeBytes { buffer in
            try QuakeTerminalURLHandler.handle(ghostty_action_open_url_s(
                kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8,
                url: XCTUnwrap(buffer.baseAddress).assumingMemoryBound(to: CChar.self),
                len: UInt(bytes.count)
            )) { _ in
                XCTFail("Opened invalid UTF-8")
                return true
            }
        }
        XCTAssertTrue(handled)
    }

    func testEmptyTargetIsHandledWithoutOpening() {
        "https://example.com".withCString { url in
            XCTAssertTrue(QuakeTerminalURLHandler.handle(ghostty_action_open_url_s(
                kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8,
                url: url,
                len: 0
            )) { _ in
                XCTFail("Opened an empty target")
                return true
            })
        }
    }

    func testFailedOpenDoesNotFallBackToGhostty() {
        var attempts = 0
        XCTAssertTrue(handle("https://example.com") { _ in
            attempts += 1
            return false
        })
        XCTAssertEqual(attempts, 1)
    }

    func testLeavesDetectedURLsAndScreenExportsToGhostty() {
        for kind in [
            GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN,
            GHOSTTY_ACTION_OPEN_URL_KIND_TEXT,
            GHOSTTY_ACTION_OPEN_URL_KIND_HTML
        ] {
            XCTAssertFalse(handle("https://example.com", kind: kind) { _ in
                XCTFail("Intercepted a non-hyperlink action")
                return true
            })
        }
    }

    private func handle(
        _ string: String,
        kind: ghostty_action_open_url_kind_e = GHOSTTY_ACTION_OPEN_URL_KIND_OSC8,
        open: (URL) -> Bool
    ) -> Bool {
        string.withCString { bytes in
            QuakeTerminalURLHandler.handle(ghostty_action_open_url_s(
                kind: kind,
                url: bytes,
                len: UInt(string.utf8.count)
            ), open: open)
        }
    }
}
