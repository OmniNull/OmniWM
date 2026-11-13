// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import TOML
import XCTest

final class AppThemeTOMLTableTests: XCTestCase {
    private let table = AppThemeTOMLTable(keys: ["theme", "custom"])
    private let section = "[theme.custom]\n# Generated\naccent = \"#cba6f7\"\npanel_bg = \"reset\"\n"

    private func parse(_ text: String) throws -> [String: TOMLNode] {
        try TOMLDecoder().decode([String: TOMLNode].self, from: Data(text.utf8))
    }

    func testReplacesOnlyTheTableBody() throws {
        let config = """
        [theme]
        name = "catppuccin"

        [theme.custom]
        accent = "#ff0000"
        red = "#ff0000"

        # Keys
        [keys]
        prefix = "ctrl+b"

        """
        let result = try table.replacing(in: config, with: section, path: "config.toml")
        XCTAssertEqual(result, """
        [theme]
        name = "catppuccin"

        \(section)
        # Keys
        [keys]
        prefix = "ctrl+b"

        """)
        XCTAssertEqual(table.current(in: result), section)
    }

    func testFindsAnIndentedTableHeader() throws {
        let config = "[ui]\nmode = 1\n  [ theme . custom ]  # colors\n  accent = \"#000000\"\n[keys]\nprefix = \"x\"\n"
        let result = try table.replacing(in: config, with: section, path: "config.toml")
        XCTAssertEqual(result.components(separatedBy: "[theme.custom]").count, 2)
        XCTAssertFalse(result.contains("#000000"))
        XCTAssertEqual(try parse(result)["keys"], .table(["prefix": .string("x")]))
    }

    func testDoesNotSwallowAnIndentedFollowingTable() throws {
        let config = "[theme.custom]\naccent = \"#000000\"\n    [keys]\n    prefix = \"ctrl+b\"\n"
        let result = try table.replacing(in: config, with: section, path: "config.toml")
        XCTAssertTrue(result.contains("    [keys]\n    prefix = \"ctrl+b\"\n"))
        XCTAssertEqual(try parse(result)["keys"], .table(["prefix": .string("ctrl+b")]))
    }

    func testIgnoresHeadersInsideStringsAndArrays() throws {
        let config = """
        [notes]
        text = \"\"\"
        [theme.custom]
        not a table
        \"\"\"
        literal = '''
        [keys]
        '''
        grid = [
          [1, 2],
          [3, 4],
        ]
        [theme.custom]
        accent = "#000000"
        quoted = "[keys]"

        """
        XCTAssertEqual(table.current(in: config), "[theme.custom]\naccent = \"#000000\"\nquoted = \"[keys]\"\n")
        let result = try table.replacing(in: config, with: section, path: "config.toml")
        let notes = try parse(result)["notes"]
        XCTAssertEqual(notes, try parse(config)["notes"])
    }

    func testKeepsLightAndDarkSubtables() throws {
        let config = "[theme.custom]\naccent = \"#000000\"\n\n[theme.custom.dark]\ntext = \"#ffffff\"\n"
        let result = try table.replacing(in: config, with: section, path: "config.toml")
        XCTAssertTrue(result.contains("[theme.custom.dark]\ntext = \"#ffffff\"\n"))
    }

    func testIgnoresArraysOfTablesWithTheSameName() {
        let config = "[[theme.custom]]\naccent = \"#000000\"\n"
        XCTAssertNil(table.current(in: config))
    }

    func testAppendsWhenTheTableIsMissing() throws {
        XCTAssertEqual(try table.replacing(in: "", with: section, path: "c"), section)
        XCTAssertEqual(
            try table.replacing(in: "[keys]\na = 1", with: section, path: "c"),
            "[keys]\na = 1\n\n" + section
        )
        XCTAssertEqual(
            try table.replacing(in: "[keys]\na = 1\n", with: section, path: "c"),
            "[keys]\na = 1\n\n" + section
        )
    }

    func testRefusesInvalidConfigsAndDuplicateDefinitions() {
        XCTAssertThrowsError(try table.replacing(in: "[keys\n", with: section, path: "c")) {
            XCTAssertEqual($0 as? AppThemeTOMLTableError, .invalidConfig("c"))
        }
        let dotted = "[theme]\ncustom.accent = \"#000000\"\n"
        XCTAssertThrowsError(try table.replacing(in: dotted, with: section, path: "c"))
        XCTAssertThrowsError(try table.replacing(in: "", with: "accent = 1\n", path: "c")) {
            XCTAssertEqual($0 as? AppThemeTOMLTableError, .invalidSection)
        }
    }

    func testReplacingTwiceIsStable() throws {
        let config = "[keys]\nprefix = \"x\"\n[theme.custom]\naccent = \"#000000\"\n[ui]\na = 1\n"
        let once = try table.replacing(in: config, with: section, path: "c")
        XCTAssertEqual(try table.replacing(in: once, with: section, path: "c"), once)
    }
}
