// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

extension ShellScriptHostTests {
    private func texts(_ script: Script) -> [String] {
        let output = script.output
        let store = strings(output)
        return decode(output).filter { $0.kind == .label }.map { store.string($0.content.text) }
    }

    func testFieldReadsSeeTableWritesMadeByMetamethods() throws {
        let written = 5
        let script = try Script("""
        local written = \(written)
        local arithmetic = setmetatable({}, { __add = function(_, value) value.a = written; return 0 end })
        local indexing = setmetatable({}, { __index = function(_, key) key.a = written; return 0 end })
        function render(ctx)
            local added = { a = 4 }
            local _ = arithmetic + added
            local keyed = { a = 4 }
            local _ = indexing[keyed]
            return ui.row{
                ui.text{ text = tostring(written) },
                ui.text{ text = tostring(added.a) },
                ui.text{ text = tostring(keyed.a) },
            }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        XCTAssertEqual(texts(script), [String(written), String(written), String(written)])
    }

    func testTableIdentifiersRemainDistinct() throws {
        let tables = 8
        let script = try Script("""
        function render(ctx)
            local made = {}
            for index = 1, \(tables) do
                made[index] = {}
            end
            local row = {}
            for index, table in made do
                row[index] = ui.text{ text = tostring(table) }
            end
            return ui.row(row)
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let identifiers = try texts(script).map { text in
            try XCTUnwrap(text.split(separator: "x").last.flatMap { UInt64($0, radix: 16) }, text)
        }
        XCTAssertEqual(Set(identifiers).count, tables)
    }
}
