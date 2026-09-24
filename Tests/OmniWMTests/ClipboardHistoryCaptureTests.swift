// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

final class ClipboardHistoryCaptureTests: XCTestCase {
    func testRetainsNativeRepresentationsAndItemGrouping() throws {
        let first = NSPasteboardItem()
        first.setData(Data("plain".utf8), forType: .string)
        first.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.adobe.pdf"))
        let second = NSPasteboardItem()
        second.setData(Data([4, 5, 6]), forType: NSPasteboard.PasteboardType("public.jpeg"))
        let third = NSPasteboardItem()
        third.setData(Data([7, 8, 9]), forType: NSPasteboard.PasteboardType("public.heic"))

        let capture = try XCTUnwrap(ClipboardHistoryPasteboard.capture(
            pasteboardItems: [first, second, third],
            configuration: configuration()
        ))

        XCTAssertEqual(capture.contents.count, 4)
        XCTAssertEqual(capture.contents.first(where: { $0.type == "com.adobe.pdf" })?.kind, .other)
        XCTAssertEqual(capture.contents.first(where: { $0.type == "com.adobe.pdf" })?.itemIndex, 0)
        XCTAssertEqual(capture.contents.first(where: { $0.type == "public.jpeg" })?.kind, .image)
        XCTAssertEqual(capture.contents.first(where: { $0.type == "public.jpeg" })?.itemIndex, 1)
        XCTAssertEqual(capture.contents.first(where: { $0.type == "public.heic" })?.kind, .image)
        XCTAssertEqual(capture.contents.first(where: { $0.type == "public.heic" })?.itemIndex, 2)
    }

    func testConfiguredIgnoredTypeRejectsEntireCopy() {
        let item = NSPasteboardItem()
        item.setData(Data("secret".utf8), forType: .string)
        item.setData(Data([1]), forType: NSPasteboard.PasteboardType("org.example.private"))

        XCTAssertNil(ClipboardHistoryPasteboard.capture(
            pasteboardItems: [item],
            configuration: configuration(ignoredTypes: ["org.example.private"])
        ))
    }

    func testConcealedTypeRejectsEntireCopy() {
        let ordinary = NSPasteboardItem()
        ordinary.setData(Data("ordinary".utf8), forType: .string)
        let concealed = NSPasteboardItem()
        concealed.setData(Data([1]), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))

        XCTAssertNil(ClipboardHistoryPasteboard.capture(
            pasteboardItems: [ordinary, concealed],
            configuration: configuration()
        ))
    }

    func testRichOnlyContentHasDerivedSearchText() throws {
        let item = NSPasteboardItem()
        item.setData(Data("<html><body><p>Readable rich content</p></body></html>".utf8), forType: .html)

        let capture = try XCTUnwrap(ClipboardHistoryPasteboard.capture(
            pasteboardItems: [item],
            configuration: configuration()
        ))

        XCTAssertTrue(capture.derivedText?.contains("Readable rich content") == true)
    }

    func testRTFOnlyContentHasDerivedSearchText() throws {
        let attributed = NSAttributedString(string: "Readable RTF content")
        let data = try XCTUnwrap(attributed.rtf(from: NSRange(location: 0, length: attributed.length)))
        let item = NSPasteboardItem()
        item.setData(data, forType: .rtf)

        let capture = try XCTUnwrap(ClipboardHistoryPasteboard.capture(
            pasteboardItems: [item],
            configuration: configuration()
        ))

        XCTAssertEqual(capture.derivedText, "Readable RTF content")
    }

    func testUnknownOnlyContentIsSkipped() {
        let item = NSPasteboardItem()
        item.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("org.example.opaque"))

        XCTAssertNil(ClipboardHistoryPasteboard.capture(
            pasteboardItems: [item],
            configuration: configuration()
        ))
    }

    func testOversizeNativeRepresentationFallsBackToText() throws {
        let item = NSPasteboardItem()
        item.setData(Data("small".utf8), forType: .string)
        item.setData(Data(repeating: 0x42, count: 32), forType: NSPasteboard.PasteboardType("com.adobe.pdf"))

        let capture = try XCTUnwrap(ClipboardHistoryPasteboard.capture(
            pasteboardItems: [item],
            configuration: configuration(maxItemBytes: 16)
        ))

        XCTAssertEqual(capture.contents.map(\.kind), [.text])
    }

    private func configuration(
        maxItemBytes: Int = 1_024,
        ignoredTypes: Set<String> = []
    ) -> ClipboardPasteboardCaptureConfiguration {
        ClipboardPasteboardCaptureConfiguration(
            maxItemBytes: maxItemBytes,
            sourceBundleIdentifier: "org.example.source",
            capturedAt: Date(timeIntervalSince1970: 1),
            ignoredTypes: ignoredTypes
        )
    }
}
