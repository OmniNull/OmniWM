// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellLiteralMetadataTests: XCTestCase {
    func testLiteralReaderPreservesStringsNumbersAndTableShapes() throws {
        let file = "component.manifest.luau"
        let source = #"""
        return {
            ["widget-name"] = "🌙\n\"quoted\"",
            values = { false, -1.25, 8, [[one
        two]], { missing = {} } },
        }
        """#
        let fields = try ShellLiteralMetadata.fields(Data(source.utf8), filename: file)
        XCTAssertEqual(fields, [
            "widget-name": .string("🌙\n\"quoted\""),
            "values": .list([
                .boolean(false),
                .number(-1.25),
                .integer(8),
                .string("one\ntwo"),
                .record(["missing": .record([:])])
            ])
        ])
    }

    func testOnlyLiteralsAreAcceptedAndErrorsIdentifyTheirSourceLine() {
        let file = "strings/en.luau"
        let prefix = ["-- test translations", "return {"]
        for entry in [
            "name = require('./name'),",
            "name = 1 + 2,",
            "name = function() end,",
            "[tostring(1)] = true,",
            #"name = "\255","#
        ] {
            let source = (prefix + [entry, "}"]).joined(separator: "\n")
            XCTAssertThrowsError(try ShellLiteralMetadata.read(Data(source.utf8), filename: file)) { error in
                XCTAssertTrue(
                    error.localizedDescription.hasPrefix("\(file):\(prefix.count + 1):"),
                    error.localizedDescription
                )
            }
        }
        for source in [
            "local title = 'x'\nreturn { title = title }",
            "return { id = 1, ['id'] = 2 }",
            "return { true, extra = 1 }"
        ] {
            XCTAssertThrowsError(try ShellLiteralMetadata.read(Data(source.utf8), filename: file), source)
        }
    }

    func testManifestMustBeARecordAndMalformedLuauPreservesTheParserDiagnostic() {
        let file = "style.luau"
        XCTAssertThrowsError(try ShellLiteralMetadata.fields(
            Data("return { 'not-a-field' }".utf8),
            filename: file
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("named fields"), error.localizedDescription)
        }
        let source = "return {\n title = )\n}"
        XCTAssertThrowsError(try ShellLiteralMetadata.fields(Data(source.utf8), filename: file)) { error in
            let line = source.prefix(while: { $0 != ")" }).split(separator: "\n").count
            XCTAssertTrue(error.localizedDescription.hasPrefix("\(file):\(line):"), error.localizedDescription)
        }
    }
}
