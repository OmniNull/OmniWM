// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellJSONTests: XCTestCase {
    func testJSONRoundTripsNullsContainersUnicodeAndNumbers() throws {
        try check(#"""
        assert(table.isfrozen(json))
        local value, err = json.decode([[{"a":[null,true,false,-2.5e3],"empty":[],"record":{},"s":"A\u0000\n\ud83d\ude00"}]])
        assert(value and err == nil)
        assert(value.a[1] == json.null and #value.a == 4)
        assert(value.a[2] == true and value.a[3] == false and value.a[4] == -2500)
        assert(value.s == "A\0\n" .. utf8.char(0x1f600))
        assert(json.encode(value.empty) == "[]")
        assert(json.encode(value.record) == "{}")
        assert(json.encode(nil) == "null" and json.encode(json.null) == "null")
        assert(json.decode("null") == json.null)
        local encoded, encodeError = json.encode(value)
        assert(encoded and encodeError == nil)
        local decoded = assert(json.decode(encoded))
        assert(decoded.a[1] == json.null and decoded.s == value.s)
        assert(json.encode(decoded.empty) == "[]")
        value.a[4] = 6
        assert(value.a[4] == 6)
        for _, number in {0, -0.0, 0.1, 9007199254740991, 1e-200, 1e200} do
            assert(json.decode(assert(json.encode(number))) == number)
        end
        """#)
    }

    func testDecodeRejectsMalformedJSONWithoutRaising() throws {
        try check(#"""
        local invalid = {
            "", " ", "nil", "NaN", "Infinity", "+1", "01", "1.", ".1", "1e", "1e+", "--1", "1e9999",
            "true false", "[]x", "[1,]", "[,1]", "[1 2]", "{a:1}", [[{"a":1,}]], [[{"a" 1}]],
            [["\x01"]], [["\u123"]], [["\ud800"]], [["\udc00"]], [["\ud800\u1234"]],
            '"' .. string.char(0) .. '"', '"' .. string.char(0xc0, 0x80) .. '"',
            '"' .. string.char(0xed, 0xa0, 0x80) .. '"', '"' .. string.char(0xf4, 0x90, 0x80, 0x80) .. '"',
            '"' .. string.char(0xe2, 0x82) .. '"',
        }
        for _, text in invalid do
            local ok, value, err = pcall(json.decode, text)
            assert(ok and value == nil and type(err) == "string", text)
        end
        local value, err = json.decode({})
        assert(value == nil and type(err) == "string")
        """#)
    }

    func testEncodeRejectsInvalidValuesWithoutInvokingMetamethods() throws {
        try check(#"""
        local cycle = {}; cycle.self = cycle
        local values = { cycle, function() end, coroutine.create(function() end), 0/0, math.huge,
            { [2] = true }, { [1] = true, name = "mixed" }, { [{}] = true }, string.char(255) }
        for _, value in values do
            local ok, encoded, err = pcall(json.encode, value)
            assert(ok and encoded == nil and type(err) == "string")
        end
        local raw = setmetatable({ value = 4 }, {
            __iter = function() error("iterator must not run") end,
            __index = function() error("index must not run") end,
            __tostring = function() error("formatter must not run") end,
        })
        assert(json.decode(assert(json.encode(raw))).value == 4)
        local shared = { value = true }
        local decoded = assert(json.decode(assert(json.encode({first = shared, second = shared}))))
        assert(decoded.first.value and decoded.second.value)
        """#)
    }

    func testDepthLimitAccepts64AndRejects65() throws {
        try check(#"""
        local text = string.rep("[", 64) .. "null" .. string.rep("]", 64)
        local value = assert(json.decode(text))
        assert(json.encode(value) == text)
        local bad, decodeError = json.decode("[" .. text .. "]")
        assert(bad == nil and string.find(decodeError, "depth"))
        local encoded, encodeError = json.encode({value})
        assert(encoded == nil and string.find(encodeError, "depth"))
        """#)
    }

    func testFourMiBInputAndOutputCapsAreExplicit() throws {
        try check(#"""
        local limit = 4 * 1024 * 1024
        local text = '"' .. string.rep("a", limit - 2) .. '"'
        local decoded, err = json.decode(text)
        assert(decoded and #decoded == limit - 2 and err == nil)
        assert(#assert(json.encode(decoded)) == limit)
        local tooLarge, inputError = json.decode(text .. " ")
        assert(tooLarge == nil and type(inputError) == "string")
        local output, outputError = json.encode(decoded .. "a")
        assert(output == nil and type(outputError) == "string")
        """#, budget: 2_000_000_000)
    }

    private func check(_ body: String, budget: UInt64 = 100_000_000) throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            \(body)
            return ui.box{}
        end
        """)
        XCTAssertEqual(script.render(budget: budget).status, OMNI_OK, script.message)
    }
}
