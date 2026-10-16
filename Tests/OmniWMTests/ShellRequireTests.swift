// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellRequireTests: XCTestCase {
    private func load(_ main: String, modules: [String: String]) throws -> (omni_status, String) {
        let vm = try XCTUnwrap(ShellVM.make(memoryLimit: 8 << 20))
        defer { _ = omni_vm_destroy(vm) }
        for (path, source) in modules {
            XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, source, source.utf8.count), OMNI_OK)
        }
        var error = [CChar](repeating: 0, count: 512)
        let status = omni_vm_load(
            vm,
            "@widgets/clock/init.luau",
            main,
            main.utf8.count,
            100_000_000,
            &error,
            error.count
        )
        return (status, error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }

    func testSelfAndRelativePathsFollowLuauRules() throws {
        let (status, message) = try load("""
        local helpers = require("@self/helpers")
        local nested = require("@self/lib")
        local shared = require("./shared")
        local again = require("@self/helpers")
        assert(helpers.value == 1 and nested.value == 2 and shared.value == 3 and again == helpers)
        assert(leaked == nil)
        """, modules: [
            "widgets/clock/helpers.luau": "leaked = true return { value = 1 }",
            "widgets/clock/lib/init.luau": "return { value = require(\"./sibling\").value }",
            "widgets/clock/sibling.luau": "return { value = 2 }",
            "widgets/shared.luau": "return { value = 3 }"
        ])
        XCTAssertEqual(status, OMNI_OK, message)
    }

    func testMissingCyclicAndAbsoluteModulesFail() throws {
        let missing = try load("require(\"@self/nope\")", modules: [:])
        XCTAssertEqual(missing.0, OMNI_ERR_RUNTIME)
        XCTAssertTrue(missing.1.contains("no module"), missing.1)

        let cycle = try load("require(\"@self/a\")", modules: [
            "widgets/clock/a.luau": "return require(\"./b\")",
            "widgets/clock/b.luau": "return require(\"./a\")"
        ])
        XCTAssertEqual(cycle.0, OMNI_ERR_RUNTIME)
        XCTAssertTrue(cycle.1.contains("requires itself"), cycle.1)

        let absolute = try load("require(\"helpers\")", modules: ["widgets/clock/helpers.luau": "return 1"])
        XCTAssertTrue(absolute.1.contains("must start with"), absolute.1)

        let escape = try load("require(\"../../../etc\")", modules: [:])
        XCTAssertEqual(escape.0, OMNI_ERR_RUNTIME)
    }
}
