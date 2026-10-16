// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

extension ShellScriptHostTests {
    func testRecoveryAfterAFailedRenderRepublishesTheSameTree() throws {
        let script = try Script("""
        function render(ctx)
            if ctx.data.mode == "fail" then
                error("broken")
            end
            return ui.text{ text = "same" }
        end
        """)
        XCTAssertEqual(script.render().stats.changed, 1)
        _ = omni_instance_set_string(script.instance, "mode", "fail", 4)
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        _ = omni_instance_set_string(script.instance, "mode", "ok", 2)
        let recovered = script.render()
        XCTAssertEqual(recovered.status, OMNI_OK, script.message)
        XCTAssertEqual(recovered.stats.changed, 1)
    }

    func testDependencyOnlyChangeRepublishesWithTheNewDependencies() throws {
        let script = try Script("""
        function render(ctx)
            local _ = if ctx.data.mode == "cpu" then ctx.data.cpu else ctx.data.memory
            return ui.text{ text = "same" }
        end
        """)
        _ = omni_instance_set_string(script.instance, "mode", "cpu", 3)
        let first = script.render().stats
        XCTAssertEqual(first.changed, 1)
        XCTAssertNotEqual(first.deps & ShellDataKey.cpu.bit, 0)

        _ = omni_instance_set_string(script.instance, "mode", "mem", 3)
        let second = script.render().stats
        XCTAssertEqual(second.changed, 1)
        XCTAssertEqual(second.deps & ShellDataKey.cpu.bit, 0)
        XCTAssertNotEqual(second.deps & ShellDataKey.memory.bit, 0)
        let published = script.output.withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self).deps }
        XCTAssertEqual(published, second.deps)
        XCTAssertEqual(script.render().stats.changed, 0)
    }

    func testSortWithoutAComparatorStaysInterruptible() throws {
        let script = try Script("""
        local values = {}
        for index = 1, 600000 do
            values[index] = (index * 7919) % 600000
        end
        function render(ctx)
            table.sort(values)
            return ui.text{ text = "sorted" }
        end
        """)
        let result = script.render(budget: 2_000_000)
        XCTAssertEqual(result.status, OMNI_ERR_TIMEOUT, script.message)
        XCTAssertLessThan(result.stats.cpu_ns, 20_000_000)
    }

    func testSortKeepsItsOrdering() throws {
        let script = try Script("""
        function render(ctx)
            local up = { 3, 1, 2 }
            table.sort(up)
            local down = { "b", "c", "a" }
            table.sort(down, function(a, b) return a > b end)
            return ui.text{ text = table.concat(up, ",") .. ";" .. table.concat(down, ",") }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let nodes = decode(script.output)
        XCTAssertEqual(strings(script.output).string(nodes[0].content.text), "1,2,3;c,b,a")
    }

    func testSortRejectsAComparatorThatIsNotAFunction() throws {
        let script = try Script("""
        function render(ctx)
            table.sort({ 2, 1 }, false)
            return ui.text{ text = "sorted" }
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertTrue(script.message.contains("function expected"), script.message)
    }

    func testOverrunInsideEncodeReportsTimeoutAfterTheCallReturns() throws {
        let script = try Script("""
        local items = {}
        for index = 1, 4000 do
            items[index] = ui.box{ w = 1, h = 1 }
        end
        local tree = ui.row(items)
        function render(ctx)
            return tree
        end
        """)
        let unbounded = script.render(budget: 0)
        XCTAssertEqual(unbounded.status, OMNI_OK, script.message)
        let result = script.render(budget: max(unbounded.stats.encode_cpu_ns / 4, 1))
        XCTAssertEqual(result.status, OMNI_ERR_TIMEOUT)
        XCTAssertEqual(script.message, "script exceeded its CPU budget")
    }

    func testResettingStringsRepublishesEveryView() throws {
        let script = try Script("""
        function render(ctx)
            return ui.text{ text = ctx.data.clock }
        end
        function popout(ctx)
            return ui.box{ w = 1, h = 1 }
        end
        """)
        _ = omni_instance_set_string(script.instance, "clock", "12:00", 5)
        XCTAssertEqual(script.render().stats.changed, 1)
        XCTAssertEqual(script.render(OMNI_VIEW_POPOUT).stats.changed, 1)
        XCTAssertEqual(script.render().stats.changed, 0)
        XCTAssertGreaterThan(omni_vm_string_count(script.vm), 0)

        omni_vm_reset_strings(script.vm)

        XCTAssertEqual(omni_vm_string_count(script.vm), 0)
        let bar = script.render().stats
        XCTAssertEqual(bar.changed, 1)
        XCTAssertEqual(bar.new_strings, 1)
        XCTAssertEqual(script.render(OMNI_VIEW_POPOUT).stats.changed, 1)
    }
}
