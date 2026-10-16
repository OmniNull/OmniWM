// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellServiceValueTests: XCTestCase {
    func testNullEmptyArrayBinaryAndNumbersRoundTripWithoutFoundationJSONCoercion() throws {
        let value = ShellServiceValue.object([
            "empty": .array([]), "null": .null, "false": .bool(false), "number": .number(2.5),
            "binary": .bytes([0, 255, 128, 1]), "text": .text("Hello 東京")
        ])
        var writer = ShellValueWriter()
        value.write(to: &writer)
        let decoded = try ShellServiceValue.decode(writer.bytes)
        XCTAssertEqual(decoded, value)
        XCTAssertNil(decoded.fields?["binary"]?.string)
        XCTAssertEqual(decoded.fields?["text"]?.string, "Hello 東京")
    }

    func testTruncationTrailingBytesInvalidTagsAndDuplicateKeysAreRejected() throws {
        var writer = ShellValueWriter()
        ShellServiceValue.object(["value": .array([.number(42), .text("sample")])]).write(to: &writer)
        for length in 0 ..< writer.bytes.count {
            XCTAssertThrowsError(try ShellServiceValue.decode(Array(writer.bytes.prefix(length))))
        }
        XCTAssertThrowsError(try ShellServiceValue.decode(writer.bytes + [0]))
        XCTAssertThrowsError(try ShellServiceValue.decode([255]))
        var duplicate = ShellValueWriter()
        duplicate.map(2)
        duplicate.key("same")
        duplicate.number(1)
        duplicate.key("same")
        duplicate.number(2)
        XCTAssertThrowsError(try ShellServiceValue.decode(duplicate.bytes))
    }

    func testByteDepthNodeAndDeclaredLengthBoundsRejectBeforeAllocatingCollections() throws {
        var writer = ShellValueWriter()
        writer.string("bounded")
        XCTAssertThrowsError(try ShellServiceValue.decode(writer.bytes, byteLimit: writer.bytes.count - 1))
        var nested = ShellServiceValue.null
        for _ in 0 ..< 64 { nested = .array([nested]) }
        writer.reset()
        nested.write(to: &writer)
        XCTAssertEqual(try ShellServiceValue.decode(writer.bytes), nested)
        XCTAssertThrowsError(try ShellServiceValue.decode(writer.bytes, nodeLimit: 64))
        writer.reset()
        ShellServiceValue.array([nested]).write(to: &writer)
        XCTAssertThrowsError(try ShellServiceValue.decode(writer.bytes))
        for tag in [OMNI_VALUE_ARRAY, OMNI_VALUE_MAP, OMNI_VALUE_STRING] {
            XCTAssertThrowsError(try ShellServiceValue.decode([UInt8(tag.rawValue), 255, 255, 255, 255]))
        }
        writer.reset()
        writer.number(.infinity)
        XCTAssertThrowsError(try ShellServiceValue.decode(writer.bytes))
    }

    func testComponentValuesAcceptOnlySchemaSupportedShapes() {
        XCTAssertEqual(ShellServiceValue.array([.text("one"), .text("two")]).componentValue, .strings(["one", "two"]))
        XCTAssertEqual(ShellServiceValue.array([]).componentValue, .strings([]))
        XCTAssertEqual(ShellServiceValue.object([:]).componentValue, .strings([]))
        XCTAssertNil(ShellServiceValue.object(["nested": .text("no")]).componentValue)
        XCTAssertNil(ShellServiceValue.array([.bool(true)]).componentValue)
        XCTAssertNil(ShellServiceValue.bytes([255]).componentValue)
    }
}
