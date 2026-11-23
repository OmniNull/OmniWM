// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class SettingsSourceTableTests: XCTestCase {
    func testConstructorRangesIncludeOriginalKeySpellingWrappersAndSeparators() throws {
        let value = #"("Café") :: string"#
        let field = #"["name"] = "# + value
        let row = "{ " + field + " }"
        let listValue = "(" + row + ")"
        let list = "{\r\n    " + listValue + " ; -- 🌓\r\n    " + listValue + "\r\n}"
        let source = Data(("return { launcher = { entries = " + list + " } }").utf8)
        let document = try SettingsLuauDocument(source)
        let entries = ["launcher", "entries"]
        let table = try XCTUnwrap(document.tables[entries])
        func text(_ bytes: Range<Int>) -> String {
            String(decoding: source[bytes], as: UTF8.self)
        }

        XCTAssertEqual(text(table.bytes), list)
        XCTAssertEqual(table.items.map { text($0.value) }, [listValue, listValue])
        XCTAssertTrue(table.items.allSatisfy { $0.key == nil && $0.bytes == $0.value })
        XCTAssertEqual(table.items.map { $0.separator.map(text) }, [";", nil])
        for (index, listItem) in table.items.enumerated() {
            let fields = try XCTUnwrap(document.tables[entries + [String(index)]])
            XCTAssertEqual(text(fields.bytes), row)
            XCTAssertTrue(listItem.value.contains(fields.bytes.lowerBound))
            XCTAssertEqual(fields.items.map(\.key), ["name"])
            let item = try XCTUnwrap(fields.items.first)
            XCTAssertEqual(text(item.bytes), field)
            XCTAssertEqual(text(item.value), value)
            XCTAssertNil(item.separator)
        }
        XCTAssertNil(document.sourceValue["general"])
        XCTAssertEqual(document.sourceValue["launcher"]?["entries"], .list([
            .record(["name": .string("Café")]), .record(["name": .string("Café")])
        ]))
    }

    func testExplicitIndexesKeepSourceOrderAndMapRowsByTheirLogicalIndex() throws {
        let names = ["one", "two", "three"]
        let sourceOrder = [2, 0, 1]
        let tokens: [String?] = ["0x3", nil, "2"]
        let rows = zip(sourceOrder, tokens).map { index, token in
            let key = token.map { "[(\($0) :: number)] = " } ?? ""
            return key + "{ name = '\(names[index])' }"
        }
        let source = Data(("return { launcher = { entries = {" + rows.joined(separator: ";") + "} } }").utf8)
        let document = try SettingsLuauDocument(source)
        let entries = ["launcher", "entries"]
        let table = try XCTUnwrap(document.tables[entries])
        func text(_ bytes: Range<Int>) -> String {
            String(decoding: source[bytes], as: UTF8.self)
        }

        XCTAssertEqual(table.items.map(\.listIndex), sourceOrder)
        XCTAssertEqual(table.items.map { $0.indexToken.map(text) }, tokens)
        XCTAssertEqual(table.items.map { text($0.bytes) }, rows)
        for (index, name) in names.enumerated() {
            let fields = try XCTUnwrap(document.tables[entries + [String(index)]])
            let item = try XCTUnwrap(fields.items.first)
            XCTAssertEqual(item.key, "name")
            XCTAssertNil(item.listIndex)
            XCTAssertNil(item.indexToken)
            XCTAssertEqual(text(item.value), "'\(name)'")
        }
    }

    func testDuplicateAndComputedListIndexesRequireReplacingTheList() throws {
        for rows in ["[1] = 'first', 'second'", "[math.ceil(1)] = 'first'"] {
            let source = Data(("return { workspaceBar = { excludedBundleIDs = {" + rows + "} } }").utf8)
            let document = try SettingsLuauDocument(source)
            let path = ["workspaceBar", "excludedBundleIDs"]
            XCTAssertNil(document.tables[path])
            XCTAssertNotNil(document.formulas[path])
        }
    }

    func testEmptyConstructorIsMappedButRepeatedAndComputedKeysAreOpaque() throws {
        let source = """
        local field = "size"
        return { gaps = { size = 1, [field] = 2 }, workspaceBar = { iconOverrides = {} } }
        """
        let document = try SettingsLuauDocument(Data(source.utf8))
        let empty = try XCTUnwrap(document.tables[["workspaceBar", "iconOverrides"]])
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertEqual(String(decoding: document.source[empty.bytes], as: UTF8.self), "{}")
        XCTAssertNil(document.tables[["gaps"]])
        XCTAssertNil(document.fields[["gaps", "size"]])
        XCTAssertNotNil(document.formulas[["gaps"]])

        let duplicate = source.replacingOccurrences(of: "[field]", with: "size")
        let repeated = try SettingsLuauDocument(Data(duplicate.utf8))
        XCTAssertNil(repeated.tables[["gaps"]])
        XCTAssertNotNil(repeated.formulas[["gaps"]])
    }
}
