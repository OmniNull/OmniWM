// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class GhosttyClipboardMIMERequestsTests: XCTestCase {
    func testRequestedMIMEsPreserveOrderAndSkipDuplicateAndUnavailableEntries() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }
        let firstMIME = "application/x-omniwm-first"
        let secondMIME = "application/x-omniwm-second"
        let firstData = Data([1, 2])
        let secondData = Data([3, 4])
        let firstType = try XCTUnwrap(NSPasteboard.PasteboardType(ghosttyMIMEType: firstMIME))
        let secondType = try XCTUnwrap(NSPasteboard.PasteboardType(ghosttyMIMEType: secondMIME))
        pasteboard.declareTypes([firstType, secondType], owner: nil)
        XCTAssertTrue(pasteboard.setData(firstData, forType: firstType))
        XCTAssertTrue(pasteboard.setData(secondData, forType: secondType))

        let payload = secondMIME.withCString { second in
            firstMIME.withCString { first in
                "application/x-omniwm-absent".withCString { absent in
                    let mimes: [UnsafePointer<CChar>] = [second, first, second, absent]
                    return mimes.withUnsafeBufferPointer {
                        pasteboard.ghosttyReadPayload(forMIMEs: $0, list: false)
                    }
                }
            }
        }

        XCTAssertEqual(try XCTUnwrap(payload).contents, [
            GhosttyClipboardContent(mime: secondMIME, data: secondData),
            GhosttyClipboardContent(mime: firstMIME, data: firstData)
        ])
        XCTAssertEqual(payload?.available, [])
    }

    func testMissingMIMEListIsUnavailableUnlessInventoryIsRequested() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }
        pasteboard.declareTypes([.string], owner: nil)
        XCTAssertTrue(pasteboard.setString("clipboard", forType: .string))

        XCTAssertNil(pasteboard.ghosttyReadPayload(forMIMEs: nil, list: false))
        let payload = try XCTUnwrap(pasteboard.ghosttyReadPayload(forMIMEs: nil, list: true))
        XCTAssertEqual(payload.contents, [])
        XCTAssertEqual(payload.available, ["text/plain"])
    }

    func testEmptyMIMEListMatchesMissingList() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }
        let mimes: [UnsafePointer<CChar>] = []

        try mimes.withUnsafeBufferPointer { buffer in
            XCTAssertNil(pasteboard.ghosttyReadPayload(forMIMEs: buffer, list: false))
            let payload = try XCTUnwrap(pasteboard.ghosttyReadPayload(forMIMEs: buffer, list: true))
            XCTAssertEqual(payload.contents, [])
            XCTAssertEqual(payload.available, [])
        }
    }

    func testUnavailableMIMEProducesNoPayloadWithoutInventory() {
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }

        "application/x-omniwm-absent".withCString { absent in
            let mimes: [UnsafePointer<CChar>] = [absent, absent]
            mimes.withUnsafeBufferPointer { buffer in
                XCTAssertNil(pasteboard.ghosttyReadPayload(forMIMEs: buffer, list: false))
                XCTAssertEqual(
                    pasteboard.ghosttyReadPayload(forMIMEs: buffer, list: true),
                    GhosttyClipboardPayload(contents: [], available: [])
                )
            }
        }
    }

    func testPlainTextRequestPreservesTextAndIncludesInventoryOnlyWhenRequested() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.clearContents() }
        pasteboard.declareTypes([.string], owner: nil)
        XCTAssertTrue(pasteboard.setString("first\nsecond", forType: .string))

        try "text/plain".withCString { text in
            let mimes: [UnsafePointer<CChar>] = [text, text]
            try mimes.withUnsafeBufferPointer { buffer in
                for list in [false, true] {
                    let payload = try XCTUnwrap(pasteboard.ghosttyReadPayload(forMIMEs: buffer, list: list))
                    XCTAssertEqual(payload.contents, [
                        GhosttyClipboardContent(mime: "text/plain", data: Data("first\nsecond".utf8))
                    ])
                    XCTAssertEqual(payload.available, list ? ["text/plain"] : [])
                }
            }
        }
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("com.omniwm.tests.quake-clipboard.\(UUID().uuidString)"))
    }
}
